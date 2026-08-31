using k8s;
using k8s.Autorest;
using k8s.Models;

namespace Video.Completion;

/// <summary>
/// Minimal Kubernetes Lease-based leader election, modeled after the standard client-go
/// leaderelection algorithm: a single Lease object records the current holder identity and a
/// renew timestamp; only the pod holding the lease runs the reconcile loop. This lets the
/// completion Deployment run multiple replicas for availability (one takes over quickly if the
/// leader pod dies or is evicted) without the reconcile logic having to be safe for concurrent
/// execution across pods.
/// </summary>
public sealed class LeaseLeaderElector(
    IKubernetes kubernetes,
    string leaseNamespace,
    string leaseName,
    string identity,
    ILogger logger,
    TimeSpan? leaseDuration = null,
    TimeSpan? retryPeriod = null)
{
    private readonly TimeSpan _leaseDuration = leaseDuration ?? TimeSpan.FromSeconds(30);
    private readonly TimeSpan _retryPeriod = retryPeriod ?? TimeSpan.FromSeconds(10);

    private bool _isLeader;

    public bool IsLeader => _isLeader;

    /// <summary>
    /// Runs until <paramref name="stoppingToken"/> is cancelled, invoking <paramref name="onLeading"/>
    /// once per acquisition while this instance holds the lease, and stopping if leadership is lost
    /// (e.g. this pod stalled long enough that the lease expired and another pod took over).
    /// </summary>
    public async Task RunAsync(Func<CancellationToken, Task> onLeading, CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                if (await TryAcquireOrRenewAsync(stoppingToken))
                {
                    if (!_isLeader)
                    {
                        _isLeader = true;
                        logger.LogInformation("Acquired completion leader lease {LeaseName} as {Identity}", leaseName, identity);
                    }

                    await onLeading(stoppingToken);
                }
                else if (_isLeader)
                {
                    _isLeader = false;
                    logger.LogWarning("Lost completion leader lease {LeaseName}; standing down", leaseName);
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                logger.LogWarning(exception, "Leader election iteration failed for lease {LeaseName}", leaseName);
            }

            try
            {
                await Task.Delay(_retryPeriod, stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    /// <summary>
    /// Attempts to become (or remain) the holder of the Lease. Returns true if this identity holds
    /// the lease after the call. Uses the Lease's resourceVersion for optimistic concurrency so that
    /// concurrent replicas racing to acquire/renew cannot both succeed.
    /// </summary>
    private async Task<bool> TryAcquireOrRenewAsync(CancellationToken cancellationToken)
    {
        V1Lease? lease;
        try
        {
            lease = await kubernetes.CoordinationV1.ReadNamespacedLeaseAsync(leaseName, leaseNamespace, cancellationToken: cancellationToken);
        }
        catch (HttpOperationException exception) when (exception.Response.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            lease = await TryCreateLeaseAsync(cancellationToken);
            if (lease is null)
                return false;
        }

        var now = DateTime.UtcNow;
        var holder = lease.Spec?.HolderIdentity;
        var renewTime = lease.Spec?.RenewTime;
        var heldByOther = !string.IsNullOrEmpty(holder) && holder != identity;
        var expired = renewTime is null || now - renewTime.Value > _leaseDuration;

        if (heldByOther && !expired)
        {
            // Someone else holds a live lease; nothing to do this cycle.
            return false;
        }

        lease.Spec ??= new V1LeaseSpec();
        lease.Spec.HolderIdentity = identity;
        lease.Spec.RenewTime = now;
        lease.Spec.AcquireTime ??= now;
        lease.Spec.LeaseDurationSeconds = (int)_leaseDuration.TotalSeconds;
        if (heldByOther)
        {
            lease.Spec.AcquireTime = now;
            lease.Spec.LeaseTransitions = (lease.Spec.LeaseTransitions ?? 0) + 1;
        }

        try
        {
            await kubernetes.CoordinationV1.ReplaceNamespacedLeaseAsync(lease, leaseName, leaseNamespace, cancellationToken: cancellationToken);
            return true;
        }
        catch (HttpOperationException exception) when (exception.Response.StatusCode == System.Net.HttpStatusCode.Conflict)
        {
            // Another replica won the race for this cycle; try again next iteration.
            return false;
        }
    }

    private async Task<V1Lease?> TryCreateLeaseAsync(CancellationToken cancellationToken)
    {
        var now = DateTime.UtcNow;
        var lease = new V1Lease
        {
            Metadata = new V1ObjectMeta { Name = leaseName, NamespaceProperty = leaseNamespace },
            Spec = new V1LeaseSpec
            {
                HolderIdentity = identity,
                AcquireTime = now,
                RenewTime = now,
                LeaseDurationSeconds = (int)_leaseDuration.TotalSeconds,
                LeaseTransitions = 0
            }
        };

        try
        {
            return await kubernetes.CoordinationV1.CreateNamespacedLeaseAsync(lease, leaseNamespace, cancellationToken: cancellationToken);
        }
        catch (HttpOperationException exception) when (exception.Response.StatusCode == System.Net.HttpStatusCode.Conflict)
        {
            // Another replica created it first; read it and let the normal acquire/renew path handle it.
            return await kubernetes.CoordinationV1.ReadNamespacedLeaseAsync(leaseName, leaseNamespace, cancellationToken: cancellationToken);
        }
    }
}
