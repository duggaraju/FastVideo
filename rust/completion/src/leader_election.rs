//! Minimal Kubernetes Lease-based leader election.
//!
//! Mirrors the hand-rolled elector used by the .NET completion worker
//! (`dotnet/VideoCompletion/LeaseLeaderElector.cs`): a single `coordination.k8s.io/v1`
//! `Lease` object is used as the mutual-exclusion primitive so that only one
//! replica of the completion worker runs the reconcile loop at a time. There is
//! no built-in leader-election helper in the `kube` crate version used here
//! (the `runtime` feature that provides one is not enabled), so this is
//! implemented directly against the Lease API using optimistic concurrency
//! (resourceVersion) and HTTP 409 conflict handling.

use anyhow::{Context, Result};
use k8s_openapi::api::coordination::v1::{Lease, LeaseSpec};
use k8s_openapi::apimachinery::pkg::apis::meta::v1::MicroTime;
use kube::Error as KubeError;
use kube::api::{Api, PostParams};
use time::OffsetDateTime;

pub struct LeaseLeaderElector {
    leases: Api<Lease>,
    lease_name: String,
    identity: String,
    lease_duration_seconds: i32,
    is_leader: bool,
}

impl LeaseLeaderElector {
    pub fn new(
        leases: Api<Lease>,
        lease_name: impl Into<String>,
        identity: impl Into<String>,
        lease_duration_seconds: i32,
    ) -> Self {
        Self {
            leases,
            lease_name: lease_name.into(),
            identity: identity.into(),
            lease_duration_seconds,
            is_leader: false,
        }
    }

    /// Attempts to acquire or renew the lease. Returns `true` if this process
    /// holds the lease after the call.
    pub async fn try_acquire_or_renew(&mut self) -> Result<bool> {
        match self.leases.get(&self.lease_name).await {
            Ok(mut lease) => {
                let now = OffsetDateTime::now_utc();
                let spec = lease.spec.get_or_insert_with(LeaseSpec::default);
                let held_by_other = match (&spec.holder_identity, &spec.renew_time) {
                    (Some(holder), Some(renew_time)) if holder != &self.identity => {
                        !lease_expired(renew_time, self.lease_duration_seconds, now)
                    }
                    _ => false,
                };

                if held_by_other {
                    self.is_leader = false;
                    return Ok(false);
                }

                let transitioning = spec.holder_identity.as_deref() != Some(self.identity.as_str());
                spec.holder_identity = Some(self.identity.clone());
                spec.lease_duration_seconds = Some(self.lease_duration_seconds);
                spec.renew_time = Some(micro_time(now));
                if transitioning {
                    spec.acquire_time = Some(micro_time(now));
                    spec.lease_transitions = Some(spec.lease_transitions.unwrap_or(0) + 1);
                }

                match self
                    .leases
                    .replace(&self.lease_name, &PostParams::default(), &lease)
                    .await
                {
                    Ok(_) => {
                        self.is_leader = true;
                        Ok(true)
                    }
                    Err(KubeError::Api(status)) if status.code == 409 => {
                        // Lost the race to another replica renewing/acquiring concurrently.
                        self.is_leader = false;
                        Ok(false)
                    }
                    Err(error) => Err(error).context("Failed to update completion leader lease"),
                }
            }
            Err(KubeError::Api(status)) if status.code == 404 => self.create_lease().await,
            Err(error) => Err(error).context("Failed to read completion leader lease"),
        }
    }

    async fn create_lease(&mut self) -> Result<bool> {
        let now = OffsetDateTime::now_utc();
        let lease = Lease {
            metadata: kube::api::ObjectMeta {
                name: Some(self.lease_name.clone()),
                ..Default::default()
            },
            spec: Some(LeaseSpec {
                holder_identity: Some(self.identity.clone()),
                lease_duration_seconds: Some(self.lease_duration_seconds),
                acquire_time: Some(micro_time(now)),
                renew_time: Some(micro_time(now)),
                lease_transitions: Some(0),
                ..Default::default()
            }),
        };

        match self.leases.create(&PostParams::default(), &lease).await {
            Ok(_) => {
                self.is_leader = true;
                Ok(true)
            }
            Err(KubeError::Api(status)) if status.code == 409 => {
                // Another replica created it first this cycle; try again next tick.
                self.is_leader = false;
                Ok(false)
            }
            Err(error) => Err(error).context("Failed to create completion leader lease"),
        }
    }

    /// Releases the lease if currently held, so another replica can take over
    /// immediately instead of waiting for expiry. Best-effort: failures are
    /// logged by the caller and do not prevent shutdown.
    pub async fn try_release(&mut self) -> Result<()> {
        if !self.is_leader {
            return Ok(());
        }

        let lease = self
            .leases
            .get(&self.lease_name)
            .await
            .context("Failed to read completion leader lease during release")?;
        let Some(mut spec) = lease.spec.clone() else {
            return Ok(());
        };
        if spec.holder_identity.as_deref() != Some(self.identity.as_str()) {
            return Ok(());
        }

        spec.holder_identity = None;
        spec.renew_time = None;
        let mut updated = lease;
        updated.spec = Some(spec);
        self.leases
            .replace(&self.lease_name, &PostParams::default(), &updated)
            .await
            .context("Failed to release completion leader lease")?;
        self.is_leader = false;
        Ok(())
    }
}

fn lease_expired(renew_time: &MicroTime, lease_duration_seconds: i32, now: OffsetDateTime) -> bool {
    let renew_seconds = renew_time.0.as_second();
    let elapsed_seconds = now.unix_timestamp() - renew_seconds;
    elapsed_seconds > i64::from(lease_duration_seconds)
}

fn micro_time(now: OffsetDateTime) -> MicroTime {
    MicroTime(
        k8s_openapi::jiff::Timestamp::from_second(now.unix_timestamp())
            .unwrap_or(k8s_openapi::jiff::Timestamp::UNIX_EPOCH),
    )
}
