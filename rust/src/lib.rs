pub mod config;
pub mod contracts;
pub mod media;
pub mod parallelism;
pub mod paths;

pub fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "spotvideo=info".into()),
        )
        .init();
}
