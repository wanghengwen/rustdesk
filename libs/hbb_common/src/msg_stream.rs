//! A stream of whole messages over a transport the program provides (an npf
//! session): the program's [`MsgSink`] decides where each message goes, and
//! what arrives is handed in through a channel. The transport encrypts and
//! authenticates, so no stream key is set.

use crate::ResultType;
use bytes::{Bytes, BytesMut};
use std::{any::Any, net::SocketAddr, sync::Arc, time::Duration};
use tokio::sync::{mpsc, Semaphore};

pub trait MsgSink: Send + Sync {
    /// Sends one message: `msg` is the protobuf message when there is one
    /// (for routing), `bytes` its encoding. Returns how many bytes went on
    /// the reliable lane, which [`MsgStream`] then takes from the credit.
    fn send(&self, msg: Option<&dyn Any>, bytes: Bytes) -> ResultType<usize>;
    /// The stream is gone (dropped).
    fn close(&self);
    fn as_any(&self) -> &dyn Any;
}

pub struct MsgStream {
    sink: Arc<dyn MsgSink>,
    rx: mpsc::UnboundedReceiver<BytesMut>,
    /// bytes the peer still takes on the reliable lane; it gives them back
    /// as it reads
    credit: Arc<Semaphore>,
    window: usize,
    addr: SocketAddr,
}

impl MsgStream {
    pub fn new(
        sink: Arc<dyn MsgSink>,
        rx: mpsc::UnboundedReceiver<BytesMut>,
        credit: Arc<Semaphore>,
        window: usize,
        addr: SocketAddr,
    ) -> Self {
        Self {
            sink,
            rx,
            credit,
            window,
            addr,
        }
    }

    pub fn sink(&self) -> &Arc<dyn MsgSink> {
        &self.sink
    }

    /// `n` bytes went on the reliable lane: the peer gives the credit back
    /// as the parts arrive; a message larger than the window takes it in steps
    async fn take_credit(&mut self, mut n: usize) -> ResultType<()> {
        while n > 0 {
            let step = n.min(self.window);
            self.credit.acquire_many(step as u32).await?.forget();
            n -= step;
        }
        Ok(())
    }

    pub async fn send(&mut self, msg: &impl protobuf::Message) -> ResultType<()> {
        let bytes = Bytes::from(msg.write_to_bytes()?);
        let n = self.sink.send(Some(msg as &dyn Any), bytes)?;
        self.take_credit(n).await
    }

    pub async fn send_bytes(&mut self, bytes: Bytes) -> ResultType<()> {
        let n = self.sink.send(None, bytes)?;
        self.take_credit(n).await
    }

    pub async fn next(&mut self) -> Option<Result<BytesMut, std::io::Error>> {
        self.rx.recv().await.map(Ok)
    }

    pub async fn next_timeout(&mut self, ms: u64) -> Option<Result<BytesMut, std::io::Error>> {
        // as TCP: None on timeout
        tokio::time::timeout(Duration::from_millis(ms), self.rx.recv())
            .await
            .ok()
            .flatten()
            .map(Ok)
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.addr
    }
}

impl Drop for MsgStream {
    fn drop(&mut self) {
        self.sink.close();
    }
}
