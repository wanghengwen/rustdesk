use crate::{quartz, Frame, Pixfmt};
use std::io;
use std::marker::PhantomData;
use std::sync::{Arc, Condvar, Mutex};

pub struct Capturer {
    inner: quartz::Capturer,
    /// the newest frame not taken yet; the display stream's thread tells
    /// when it puts one
    frame: Arc<(Mutex<Option<quartz::Frame>>, Condvar)>,
    saved_raw_data: Vec<u8>, // for faster compare and copy
}

impl Capturer {
    pub fn new(display: Display) -> io::Result<Capturer> {
        let frame = Arc::new((Mutex::new(None), Condvar::new()));

        let f = frame.clone();
        let inner = quartz::Capturer::new(
            display.0,
            display.width(),
            display.height(),
            quartz::PixelFormat::Argb8888,
            Default::default(),
            move |inner| {
                if let Ok(mut slot) = f.0.lock() {
                    *slot = Some(inner);
                    f.1.notify_one();
                }
            },
        )
        .map_err(|_| io::Error::from(io::ErrorKind::Other))?;

        Ok(Capturer {
            inner,
            frame,
            saved_raw_data: Vec::new(),
        })
    }

    pub fn width(&self) -> usize {
        self.inner.width()
    }

    pub fn height(&self) -> usize {
        self.inner.height()
    }
}

impl crate::TraitCapturer for Capturer {
    /// The next frame, waited for up to `timeout` (as the other platforms'
    /// capturers wait): taken when the display stream gives it. Looked for
    /// only once a frame time, it had waited up to a frame time of the
    /// display (8 ms on average at 60 Hz) before it was encoded. It still
    /// has when frames are taken slower than the display gives them: the
    /// newest then waits for the caller.
    fn frame<'a>(&'a mut self, timeout: std::time::Duration) -> io::Result<Frame<'a>> {
        let (slot, came) = &*self.frame;
        let frame = {
            let guard = slot.lock().map_err(|_| io::ErrorKind::Other)?;
            let (mut guard, _) = came
                .wait_timeout_while(guard, timeout, |f| f.is_none())
                .map_err(|_| io::ErrorKind::Other)?;
            guard.take()
        };
        let Some(mut frame) = frame else {
            return Err(io::ErrorKind::WouldBlock.into());
        };
        crate::would_block_if_equal(&mut self.saved_raw_data, frame.inner())?;
        frame.surface_to_bgra(self.height());
        Ok(Frame::PixelBuffer(PixelBuffer {
            frame,
            data: PhantomData,
            width: self.width(),
            height: self.height(),
        }))
    }
}

pub struct PixelBuffer<'a> {
    frame: quartz::Frame,
    data: PhantomData<&'a [u8]>,
    width: usize,
    height: usize,
}

impl<'a> crate::TraitPixelBuffer for PixelBuffer<'a> {
    fn data(&self) -> &[u8] {
        &*self.frame
    }

    fn width(&self) -> usize {
        self.width
    }

    fn height(&self) -> usize {
        self.height
    }

    fn stride(&self) -> Vec<usize> {
        let mut v = Vec::new();
        v.push(self.frame.stride());
        v
    }

    fn pixfmt(&self) -> Pixfmt {
        Pixfmt::BGRA
    }
}

pub struct Display(quartz::Display);

impl Display {
    pub fn primary() -> io::Result<Display> {
        Ok(Display(quartz::Display::primary()))
    }

    pub fn all() -> io::Result<Vec<Display>> {
        Ok(quartz::Display::online()
            .map_err(|_| io::Error::from(io::ErrorKind::Other))?
            .into_iter()
            .map(Display)
            .collect())
    }

    pub fn width(&self) -> usize {
        self.0.width()
    }

    pub fn height(&self) -> usize {
        self.0.height()
    }

    pub fn scale(&self) -> f64 {
        self.0.scale()
    }

    pub fn name(&self) -> String {
        self.0.id().to_string()
    }

    pub fn is_online(&self) -> bool {
        self.0.is_online()
    }

    pub fn origin(&self) -> (i32, i32) {
        let o = self.0.bounds().origin;
        (o.x as _, o.y as _)
    }

    pub fn is_primary(&self) -> bool {
        self.0.is_primary()
    }
}
