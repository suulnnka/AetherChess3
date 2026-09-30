// Self-play data generation: shallow searches from random openings,
// records (position, stm, qsearch/root score, game result) in .aet2 files.

use crate::movegen::gen_legal;
use crate::position::Position;
use crate::search::Limits;
use crate::search::Searcher;
use crate::types::*;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed | 1)
    }
    pub fn next(&mut self) -> u64 {
        // xorshift64*
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }
    pub fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

pub struct Record {
    pub boards: [u64; 8],
    pub side: u8,
    pub score: i16,
    pub result: u8, // 0 loss, 1 draw, 2 win (side-to-move POV)
}

pub const REC_BYTES: usize = 72;

pub fn serialize_record(r: &Record) -> [u8; REC_BYTES] {
    let mut b = [0u8; REC_BYTES];
    for (i, v) in r.boards.iter().enumerate() {
        b[i * 8..i * 8 + 8].copy_from_slice(&v.to_le_bytes());
    }
    b[64] = r.side;
    b[65] = 0;
    b[66..68].copy_from_slice(&r.score.to_le_bytes());
    b[68] = r.result;
    b
}

fn boards_of(p: &Position) -> [u64; 8] {
    [
        p.occ[0],
        p.occ[1],
        p.pieces[0][PAWN as usize] | p.pieces[1][PAWN as usize],
        p.pieces[0][KNIGHT as usize] | p.pieces[1][KNIGHT as usize],
        p.pieces[0][BISHOP as usize] | p.pieces[1][BISHOP as usize],
        p.pieces[0][ROOK as usize] | p.pieces[1][ROOK as usize],
        p.pieces[0][QUEEN as usize] | p.pieces[1][QUEEN as usize],
        p.pieces[0][KING as usize] | p.pieces[1][KING as usize],
    ]
}

fn insufficient_material(p: &Position) -> bool {
    if p.pieces[0][PAWN as usize] | p.pieces[1][PAWN as usize] | p.pieces[0][ROOK as usize] | p.pieces[1][ROOK as usize] | p.pieces[0][QUEEN as usize] | p.pieces[1][QUEEN as usize] != 0 {
        return false;
    }
    let minors = (p.pieces[0][KNIGHT as usize] | p.pieces[0][BISHOP as usize] | p.pieces[1][KNIGHT as usize] | p.pieces[1][BISHOP as usize]).count_ones();
    minors <= 1
}

static GAMES_DONE: AtomicU64 = AtomicU64::new(0);

fn worker(id: usize, games: u64, out_dir: &str, seed: u64, dlo: i32, dhi: i32, opening_plies: usize, ply_cap: usize) -> u64 {
    crate::runner::QUIET.store(true, std::sync::atomic::Ordering::Relaxed);
    let mut s = Searcher::new(16);
    let mut rng = Rng::new(seed);
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mut produced = 0u64;
    let path = format!("{}/w{:02}.aet2", out_dir, id);
    let mut file = std::fs::File::create(&path).expect("create datagen output");

    for _g in 0..games {
        let mut pos = Position::from_fen(STARTPOS_FEN).unwrap();
        let mut records: Vec<(Position, i16, usize)> = Vec::with_capacity(256); // (pos, score, stm)
        let mut result: f32 = 0.5;

        // Random opening.
        let opener_len = opening_plies + rng.below(4) as usize;
        let mut opening_hashes: Vec<u64> = vec![pos.hash];
        for _ in 0..opener_len {
            let list = gen_legal(&pos);
            if list.len == 0 {
                break;
            }
            let m = list.moves[rng.below(list.len as u64) as usize];
            let mut p2 = pos;
            p2.make_move(m);
            if opening_hashes.contains(&p2.hash) {
                continue; // avoid immediate repetition in the opening
            }
            opening_hashes.push(p2.hash);
            pos = p2;
        }

        // Guided self-play.
        let mut hist: Vec<u64> = vec![pos.hash];
        let mut ply = 0usize;
        let mut consec_big = 0i32;
        let mut outcome: Option<f32> = None;
        let mut outcome_pov = pos.side; // whose POV `outcome` is expressed in
        loop {
            let mut lim = Limits::default();
            let d = dlo + rng.below((dhi - dlo + 1) as u64) as i32;
            lim.depth = d;
            let r = s.think(&pos, lim, stop.clone(), &hist);
            if r.best.is_null() {
                // mate or stalemate
                let in_check = pos.in_check(pos.side);
                outcome_pov = pos.side;
                outcome = Some(if in_check { 0.0 } else { 0.5 }); // side to move is mated or stalemated
                break;
            }
            let score = r.score.clamp(-2000, 2000) as i16;
            records.push((pos, score, pos.side as usize));

            pos.make_move(r.best);
            hist.push(pos.hash);
            ply += 1;


            if pos.halfmove >= 100 || insufficient_material(&pos) || ply >= ply_cap {
                outcome_pov = pos.side;
                outcome = Some(0.5);
                break;
            }
            consec_big = if score.abs() >= 2000 { consec_big + 1 } else { 0 };
            if consec_big >= 4 {
                // score was the mover's (side that just moved) POV
                outcome_pov = pos.side ^ 1;
                outcome = Some(if score > 0 { 1.0 } else { 0.0 });
                break;
            }
        }
        let result = outcome.unwrap_or(0.5);

        let mut buf: Vec<u8> = Vec::with_capacity(records.len() * REC_BYTES);
        for (p, score, _stm) in &records {
            let stm = p.side;
            // result is stm-POV of outcome_pov; flip for records with the other side to move
            let res = if stm == outcome_pov { result } else { 1.0 - result };
            let res10 = (res * 2.0).round() as u8; // 0/1/2
            let rec = Record {
                boards: boards_of(p),
                side: stm,
                score: *score,
                result: res10,
            };
            buf.extend_from_slice(&serialize_record(&rec));
            produced += 1;
        }
        file.write_all(&buf).expect("write datagen record");

        let done = GAMES_DONE.fetch_add(1, Ordering::Relaxed) + 1;
        if done % 500 == 0 {
            eprintln!("datagen: {} games done, {} positions", done, produced);
        }
        s.clear();

    }
    produced
}

pub fn run(workers: usize, games: u64, out_dir: &str, seed: u64, dlo: i32, dhi: i32) {
    std::fs::create_dir_all(out_dir).expect("create datagen dir");
    let mut handles = Vec::new();
    for id in 0..workers {
        let dir = out_dir.to_string();
        let sd = seed + id as u64 * 0x9E3779B9;
        handles.push(std::thread::spawn(move || worker(id, games, &dir, sd, dlo, dhi, 6, 220)));
    }
    let mut total = 0u64;
    for h in handles {
        total += h.join().unwrap_or(0);
    }
    eprintln!("datagen complete: {} positions total", total);
}
