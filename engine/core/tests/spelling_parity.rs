//! 选同音词的候选和 Arion 逐条对得上：Arion 的 457 条用例（apps/desktop/infrastructure/llm/spelling/
//! testdata/producer-parity.json@d2108fe，lexicon_test.go 的 TestEvaluatedProducerParity），
//! 再加上 TestSourceIdentityAndAmbiguity。

use std::collections::{BTreeMap, HashMap};
use wotype_core::polish::spelling::{apply_choices, load, lexicon, Lexicon};

#[derive(Debug, Clone)]
enum Json {
    Str(String),
    Num(f64),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
    Other,
}

struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}

impl Parser<'_> {
    fn ws(&mut self) {
        while self.i < self.s.len() && (self.s[self.i] as char).is_ascii_whitespace() {
            self.i += 1;
        }
    }
    fn value(&mut self) -> Json {
        self.ws();
        match self.s[self.i] {
            b'"' => Json::Str(self.string()),
            b'[' => {
                self.i += 1;
                let mut v = Vec::new();
                loop {
                    self.ws();
                    if self.s[self.i] == b']' {
                        self.i += 1;
                        return Json::Arr(v);
                    }
                    v.push(self.value());
                    self.ws();
                    if self.s[self.i] == b',' {
                        self.i += 1;
                    }
                }
            }
            b'{' => {
                self.i += 1;
                let mut v = Vec::new();
                loop {
                    self.ws();
                    if self.s[self.i] == b'}' {
                        self.i += 1;
                        return Json::Obj(v);
                    }
                    let k = self.string();
                    self.ws();
                    self.i += 1; // :
                    v.push((k, self.value()));
                    self.ws();
                    if self.s[self.i] == b',' {
                        self.i += 1;
                    }
                }
            }
            b'-' | b'0'..=b'9' => {
                let start = self.i;
                while self.i < self.s.len() && b"-+.eE0123456789".contains(&self.s[self.i]) {
                    self.i += 1;
                }
                Json::Num(std::str::from_utf8(&self.s[start..self.i]).unwrap().parse().unwrap())
            }
            _ => {
                while self.i < self.s.len() && self.s[self.i].is_ascii_alphabetic() {
                    self.i += 1;
                }
                Json::Other
            }
        }
    }
    fn string(&mut self) -> String {
        self.i += 1;
        let mut out = Vec::new();
        loop {
            let b = self.s[self.i];
            self.i += 1;
            match b {
                b'"' => return String::from_utf8(out).unwrap(),
                b'\\' => {
                    let e = self.s[self.i];
                    self.i += 1;
                    match e {
                        b'n' => out.push(b'\n'),
                        b't' => out.push(b'\t'),
                        b'r' => out.push(b'\r'),
                        b'u' => {
                            let hex = std::str::from_utf8(&self.s[self.i..self.i + 4]).unwrap();
                            self.i += 4;
                            let c = char::from_u32(u32::from_str_radix(hex, 16).unwrap()).unwrap();
                            out.extend(c.to_string().bytes());
                        }
                        other => out.push(other),
                    }
                }
                other => out.push(other),
            }
        }
    }
}

impl Json {
    fn get(&self, key: &str) -> &Json {
        match self {
            Json::Obj(v) => &v.iter().find(|(k, _)| k == key).unwrap().1,
            _ => panic!("not an object"),
        }
    }
    fn str(&self) -> &str {
        match self {
            Json::Str(s) => s,
            _ => panic!("not a string"),
        }
    }
    fn arr(&self) -> &[Json] {
        match self {
            Json::Arr(v) => v,
            _ => panic!("not an array"),
        }
    }
    fn num(&self) -> usize {
        match self {
            Json::Num(n) => *n as usize,
            _ => panic!("not a number"),
        }
    }
}

fn lex() -> &'static Lexicon {
    let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../WoType/WoType/Resources/spelling/");
    let readings = std::fs::read_to_string(format!("{root}pypinyin-character-readings-v1-readings.json")).unwrap();
    let dict = std::fs::read_to_string(format!("{root}cmudict-pronunciation-v1-cmudict.dict")).unwrap();
    assert!(load(&readings, &dict));
    lexicon().unwrap()
}

#[test]
fn producer_parity() {
    let l = lex();
    let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/tests/data/spelling-producer-parity.json")).unwrap();
    let cases = Parser { s: text.as_bytes(), i: 0 }.value();
    assert_eq!(cases.arr().len(), 457, "incomplete producer parity corpus");
    for (i, want) in cases.arr().iter().enumerate() {
        let context: BTreeMap<String, String> = match want.get("context") {
            Json::Obj(v) => v.iter().map(|(k, v)| (k.clone(), v.str().to_string())).collect(),
            _ => BTreeMap::new(),
        };
        // Arion 的用例用的是 Prepare（不拼英文字母的候选）
        let got = l.prepare(want.get("source").str(), context, want.get("scene").str(), false);
        let hyps = want.get("hypotheses").arr();
        assert_eq!(got.hypotheses.len(), hyps.len(), "case {i}: {:?}", got.hypotheses);
        for (g, w) in got.hypotheses.iter().zip(hyps) {
            assert_eq!(g.id, w.get("id").str(), "case {i}");
            assert_eq!(g.start, w.get("startUtf8").num(), "case {i}");
            assert_eq!(g.end, w.get("endUtf8").num(), "case {i}");
            assert_eq!(g.source, w.get("sourceSpan").str(), "case {i}");
            let cands: Vec<&str> = w.get("candidateSpellings").arr().iter().map(Json::str).collect();
            assert_eq!(g.candidates, cands, "case {i}");
            assert_eq!(g.status, w.get("status").str(), "case {i}");
            assert_eq!(g.kind, w.get("kind").str(), "case {i}");
        }
        let unknown: Vec<&str> = want.get("unknownChineseCharacters").arr().iter().map(Json::str).collect();
        assert_eq!(got.unknown, unknown, "case {i}");
    }
}

#[test]
fn source_identity_and_ambiguity() {
    let l = lex();
    let context = BTreeMap::from([("Screen".to_string(), "陈语楠 陈宇南".to_string())]);
    let mut p = l.prepare("请联系陈雨南。", context, "work", false);
    assert_eq!(p.hypotheses.len(), 1);
    assert_eq!(p.hypotheses[0].status, "ambiguous");
    let replace = HashMap::from([("e0".to_string(), "replace".to_string())]);
    assert!(apply_choices(&p, &replace).is_none(), "accepted ambiguous replacement");
    p.hypotheses[0].source = "other source".into();
    let keep = HashMap::from([("e0".to_string(), "keep".to_string())]);
    assert!(apply_choices(&p, &keep).is_none(), "accepted mismatched source");
}

#[test]
fn replaces_unique_candidate() {
    let l = lex();
    let context = BTreeMap::from([("Screen".to_string(), "请发到飞书群".to_string())]);
    let p = l.prepare("请把纪要发到飞鼠。", context, "chat", true);
    assert_eq!(p.hypotheses.len(), 1, "{:?}", p.hypotheses);
    // 长的候选优先：上下文里有「发到飞书」（speech_repair_test.go 的 TestASRCorrectionDoesNotSwapUnrelatedWords 也只看包含「飞书」）
    assert_eq!(p.hypotheses[0].candidates, vec!["发到飞书"]);
    let replace = HashMap::from([("e0".to_string(), "replace".to_string())]);
    assert_eq!(apply_choices(&p, &replace).unwrap(), "请把纪要发到飞书。");
}
