//! Attaches to the npf of a data directory as APP and prints what comes,
//! a line each, for SECS seconds: `attach DIR APP SECS`. The Rust client's
//! checks of npf on real Windows (scripts/win-applink-test.sh, WA-16).

use applink::{Event, Link, Options};
use std::time::Duration;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 {
        eprintln!("usage: attach DIR APP SECS");
        std::process::exit(2);
    }
    let mut o = Options::new(&a[2], &["rustdesk/1"]);
    o.dir = Some(a[1].clone().into());
    let secs = a[3].parse().unwrap_or(5);
    let (link, mut ev) = match Link::start(o) {
        Ok(x) => x,
        Err(e) => {
            println!("start {e}");
            std::process::exit(1);
        }
    };
    let end = tokio::time::sleep(Duration::from_secs(secs));
    tokio::pin!(end);
    loop {
        tokio::select! {
            _ = &mut end => break,
            e = ev.recv() => match e {
                Some(Event::Up) => println!("up {:?}", link.transport()),
                Some(Event::Down(e)) => println!("down {} {}", e.kind.word(), e.message.unwrap_or_default()),
                Some(Event::Info(i)) => println!("info {} online={}", i.number.unwrap_or(0), i.online),
                Some(Event::Peer(p)) => {
                    for s in &p.services {
                        println!("peer {} {} svc={} up={}", p.number, s.res, s.svc, s.up);
                    }
                }
                Some(_) => {}
                None => break,
            },
        }
    }
    link.stop().await;
}
