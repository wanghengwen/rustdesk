//! iOS: RustDesk's `ipc` is not built there, but a connection's `call`
//! still runs over an in-memory pipe framed as the IPC frames it (`ui`):
//! the IPC's connection type and the one message npf sends on it, the same
//! names, so `ui` and `call` read alike on every platform.

use hbb_common::{
    bail,
    bytes::{Bytes, BytesMut},
    bytes_codec::BytesCodec,
    futures::{SinkExt, StreamExt},
    tokio::io::{AsyncRead, AsyncWrite},
    tokio_util::codec::Framed,
    ResultType,
};
use serde_derive::{Deserialize, Serialize};

/// `ipc::Data`'s variant npf uses
#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "t", content = "c")]
pub enum Data {
    Config((String, Option<String>)),
}

/// `ipc::ConnectionTmpl`: a message or raw bytes a frame
pub struct ConnectionTmpl<T> {
    inner: Framed<T, BytesCodec>,
}

impl<T> ConnectionTmpl<T>
where
    T: AsyncRead + AsyncWrite + std::marker::Unpin,
{
    pub fn new(conn: T) -> Self {
        Self { inner: Framed::new(conn, BytesCodec::new()) }
    }

    pub async fn send(&mut self, data: &Data) -> ResultType<()> {
        self.inner.send(Bytes::from(serde_json::to_vec(data)?)).await?;
        Ok(())
    }

    pub async fn next(&mut self) -> ResultType<Option<Data>> {
        match self.inner.next().await {
            Some(res) => Ok(serde_json::from_slice(&res?).ok()),
            None => bail!("reset by the peer"),
        }
    }

    pub async fn send_raw(&mut self, data: Bytes) -> ResultType<()> {
        self.inner.send(data).await?;
        Ok(())
    }

    pub async fn next_raw(&mut self) -> ResultType<BytesMut> {
        match self.inner.next().await {
            Some(Ok(res)) => Ok(res),
            _ => bail!("reset by the peer"),
        }
    }
}
