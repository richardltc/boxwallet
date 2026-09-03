//! BIP39 mnemonic generation (English) for coins whose wallet CLI restores from a
//! standard BIP39 phrase but can't create one headlessly. Epic is the case in
//! point: `epic-wallet owner_api` refuses to start until a wallet exists, and the
//! new-wallet `init` subcommand reads its password straight from the controlling
//! TTY (`rpassword`) — so under BoxWallet's detached spawn the only way to
//! bootstrap a wallet is `init -r` with a recovery phrase on stdin. To *create* a
//! wallet we therefore generate a fresh phrase here (OS-CSPRNG entropy + BIP39
//! checksum) and restore it, exactly as if the user had supplied it.
//!
//! Pure std (`std.crypto`); no allocation. The mnemonic is a secret — callers pass
//! a bounded `out` buffer and wipe it once the phrase has been handed off.

const std = @import("std");

/// A 24-word mnemonic never exceeds this many bytes (24 × ≤8-char word + 23
/// spaces), so callers size their (wiped) buffer to it.
pub const max_mnemonic_len = 24 * 9;

/// Generate a fresh BIP39 English mnemonic of `word_count` words into `out`,
/// returning the populated slice (single-space separated). Supported counts: 24
/// (256-bit entropy) and 12 (128-bit) — Epic's default is 24. Entropy is drawn
/// from the platform CSPRNG via `io.random` (the OS-seeded source
/// `conf.randomPassword` also uses); the trailing checksum is the top bits of the
/// SHA-256 of that entropy, so the phrase validates and restores through
/// `epic-wallet init -r`.
pub fn generate(io: std.Io, word_count: usize, out: []u8) ![]const u8 {
    const ent_bytes: usize = switch (word_count) {
        24 => 32,
        12 => 16,
        else => return error.UnsupportedWordCount,
    };

    // entropy ++ one checksum byte (its top `ent_bytes/4` bits are the checksum:
    // 8 bits for 24 words, 4 for 12 — both fit in a single byte).
    var data: [33]u8 = undefined;
    defer @memset(&data, 0);
    io.random(data[0..ent_bytes]);

    var digest: [32]u8 = undefined;
    defer @memset(&digest, 0);
    std.crypto.hash.sha2.Sha256.hash(data[0..ent_bytes], &digest, .{});
    data[ent_bytes] = digest[0];

    return assemble(data[0 .. ent_bytes + 1], word_count, out);
}

/// Pack `word_count` words from `data` (entropy followed by the checksum byte) by
/// reading 11-bit groups MSB-first and joining the corresponding words with single
/// spaces into `out`. Split out from `generate` so a known-entropy vector can test
/// the exact bit-packing the live path runs.
fn assemble(data: []const u8, word_count: usize, out: []u8) ![]const u8 {
    var acc: u32 = 0;
    var nbits: usize = 0;
    var bi: usize = 0;
    var n: usize = 0;
    var w: usize = 0;
    while (w < word_count) : (w += 1) {
        while (nbits < 11) {
            acc = (acc << 8) | data[bi];
            bi += 1;
            nbits += 8;
        }
        const shift: u5 = @intCast(nbits - 11);
        const idx: usize = (acc >> shift) & 0x7FF;
        nbits -= 11;
        const word = wordlist[idx];
        if (w != 0) {
            out[n] = ' ';
            n += 1;
        }
        @memcpy(out[n .. n + word.len], word);
        n += word.len;
    }
    return out[0..n];
}

/// A BIP39 seed is 512 bits, so its hex spelling is 128 characters. This is what
/// a wallet reports as its raw `hdseed` — the value derived *from* the mnemonic
/// (plus any passphrase), and the thing a coin's `-hdseed` option takes instead
/// of words.
pub const hex_seed_len = 128;

/// Whether `s` is a 512-bit seed written as hex, rather than a mnemonic.
///
/// The two inputs are unambiguous by construction: every BIP39 word is at least
/// three letters and none is a bare hex run of this length, and a 128-character
/// hex string is never a word list. So one input field can take either and the
/// caller can tell them apart without asking the user which they hold — which is
/// the point, since people generally have one or the other and don't necessarily
/// know the difference in name.
pub fn looksLikeHexSeed(s: []const u8) bool {
    if (s.len != hex_seed_len) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// The index of `word` in the English wordlist, or null if it isn't in it.
/// Linear scan — the list is 2048 entries and this runs once per word of a
/// phrase a human just typed, so a lookup table would cost more than it saves.
pub fn wordIndex(word: []const u8) ?u11 {
    for (wordlist, 0..) |w, i| {
        if (std.mem.eql(u8, w, word)) return @intCast(i);
    }
    return null;
}

/// Why a mnemonic failed `validate`, so a front-end can say which of the three
/// mistakes the user actually made rather than a flat "invalid seed".
pub const Invalid = error{
    /// Not one of the BIP39 lengths (12/15/18/21/24 words).
    BadWordCount,
    /// Some word isn't in the English BIP39 wordlist — a typo or a phrase from a
    /// different wordlist.
    UnknownWord,
    /// Every word is real and the length is right, but the trailing checksum
    /// doesn't match: a word was mistyped into a *different* valid word, or two
    /// words were transposed. This is the one a wordlist check alone can't catch.
    BadChecksum,
};

/// Validate an English BIP39 mnemonic: length, wordlist membership, and the
/// trailing checksum. `seed` must already be normalized (lowercase, single
/// spaces — `models.normalizeSeedWords`).
///
/// Worth doing client-side even where the coin's daemon validates too: it turns a
/// mistyped word into an instant, specific message instead of a daemon start that
/// fails a minute later, and `BadChecksum` is exactly the transposition a user
/// stares straight past. Nothing here is secret-bearing beyond `seed` itself,
/// which the caller owns and wipes.
pub fn validate(seed: []const u8) Invalid!void {
    // Collect the 11-bit indices, counting words as we go.
    var idx: [24]u11 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, seed, ' ');
    while (it.next()) |word| {
        if (count == idx.len) return error.BadWordCount;
        idx[count] = wordIndex(word) orelse return error.UnknownWord;
        count += 1;
    }
    switch (count) {
        12, 15, 18, 21, 24 => {},
        else => return error.BadWordCount,
    }

    // Unpack the indices back into entropy ++ checksum bits (11 bits per word,
    // MSB-first) — the exact inverse of `assemble`.
    const ent_bits = count * 11 * 32 / 33; // 128,160,192,224,256
    const ent_bytes = ent_bits / 8;
    var data: [33]u8 = undefined;
    defer @memset(&data, 0);
    var acc: u32 = 0;
    var nbits: usize = 0;
    var n: usize = 0;
    for (idx[0..count]) |w| {
        acc = (acc << 11) | w;
        nbits += 11;
        while (nbits >= 8) : (nbits -= 8) {
            const shift: u5 = @intCast(nbits - 8);
            data[n] = @truncate(acc >> shift);
            n += 1;
        }
    }
    // `nbits` leftover bits are the low end of the final checksum byte; the
    // checksum we compare is the top `ent_bytes/4` bits of SHA-256(entropy).
    const tail_bits: u3 = @intCast(nbits);
    const got_tail: u8 = if (tail_bits == 0) 0 else @truncate(acc << @as(u5, 8 - @as(u5, tail_bits)));

    var digest: [32]u8 = undefined;
    defer @memset(&digest, 0);
    std.crypto.hash.sha2.Sha256.hash(data[0..ent_bytes], &digest, .{});

    const cs_bits = ent_bits / 32; // 4,5,6,7,8
    // The checksum sits in `data[ent_bytes]` when it was byte-aligned (24 words,
    // 8 bits), otherwise in the leftover `tail_bits`.
    const got: u8 = if (tail_bits == 0) data[ent_bytes] else got_tail;
    const mask: u8 = @truncate(@as(u16, 0xFF) << @as(u4, @intCast(8 - cs_bits)));
    if ((got & mask) != (digest[0] & mask)) return error.BadChecksum;
}

// BIP39 English wordlist (the canonical 2048-word list from bitcoin/bips,
// bip-0039/english.txt, sha256 2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda).
// Epic/Grin wallets use standard BIP39 mnemonics, so a phrase built from this
// list with a correct checksum restores cleanly via `epic-wallet init -r`.
pub const wordlist = [2048][]const u8{
    "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract", "absurd",
    "abuse", "access", "accident", "account", "accuse", "achieve", "acid", "acoustic",
    "acquire", "across", "act", "action", "actor", "actress", "actual", "adapt", "add",
    "addict", "address", "adjust", "admit", "adult", "advance", "advice", "aerobic", "affair",
    "afford", "afraid", "again", "age", "agent", "agree", "ahead", "aim", "air", "airport",
    "aisle", "alarm", "album", "alcohol", "alert", "alien", "all", "alley", "allow", "almost",
    "alone", "alpha", "already", "also", "alter", "always", "amateur", "amazing", "among",
    "amount", "amused", "analyst", "anchor", "ancient", "anger", "angle", "angry", "animal",
    "ankle", "announce", "annual", "another", "answer", "antenna", "antique", "anxiety", "any",
    "apart", "apology", "appear", "apple", "approve", "april", "arch", "arctic", "area",
    "arena", "argue", "arm", "armed", "armor", "army", "around", "arrange", "arrest", "arrive",
    "arrow", "art", "artefact", "artist", "artwork", "ask", "aspect", "assault", "asset",
    "assist", "assume", "asthma", "athlete", "atom", "attack", "attend", "attitude", "attract",
    "auction", "audit", "august", "aunt", "author", "auto", "autumn", "average", "avocado",
    "avoid", "awake", "aware", "away", "awesome", "awful", "awkward", "axis", "baby",
    "bachelor", "bacon", "badge", "bag", "balance", "balcony", "ball", "bamboo", "banana",
    "banner", "bar", "barely", "bargain", "barrel", "base", "basic", "basket", "battle",
    "beach", "bean", "beauty", "because", "become", "beef", "before", "begin", "behave",
    "behind", "believe", "below", "belt", "bench", "benefit", "best", "betray", "better",
    "between", "beyond", "bicycle", "bid", "bike", "bind", "biology", "bird", "birth",
    "bitter", "black", "blade", "blame", "blanket", "blast", "bleak", "bless", "blind",
    "blood", "blossom", "blouse", "blue", "blur", "blush", "board", "boat", "body", "boil",
    "bomb", "bone", "bonus", "book", "boost", "border", "boring", "borrow", "boss", "bottom",
    "bounce", "box", "boy", "bracket", "brain", "brand", "brass", "brave", "bread", "breeze",
    "brick", "bridge", "brief", "bright", "bring", "brisk", "broccoli", "broken", "bronze",
    "broom", "brother", "brown", "brush", "bubble", "buddy", "budget", "buffalo", "build",
    "bulb", "bulk", "bullet", "bundle", "bunker", "burden", "burger", "burst", "bus",
    "business", "busy", "butter", "buyer", "buzz", "cabbage", "cabin", "cable", "cactus",
    "cage", "cake", "call", "calm", "camera", "camp", "can", "canal", "cancel", "candy",
    "cannon", "canoe", "canvas", "canyon", "capable", "capital", "captain", "car", "carbon",
    "card", "cargo", "carpet", "carry", "cart", "case", "cash", "casino", "castle", "casual",
    "cat", "catalog", "catch", "category", "cattle", "caught", "cause", "caution", "cave",
    "ceiling", "celery", "cement", "census", "century", "cereal", "certain", "chair", "chalk",
    "champion", "change", "chaos", "chapter", "charge", "chase", "chat", "cheap", "check",
    "cheese", "chef", "cherry", "chest", "chicken", "chief", "child", "chimney", "choice",
    "choose", "chronic", "chuckle", "chunk", "churn", "cigar", "cinnamon", "circle", "citizen",
    "city", "civil", "claim", "clap", "clarify", "claw", "clay", "clean", "clerk", "clever",
    "click", "client", "cliff", "climb", "clinic", "clip", "clock", "clog", "close", "cloth",
    "cloud", "clown", "club", "clump", "cluster", "clutch", "coach", "coast", "coconut",
    "code", "coffee", "coil", "coin", "collect", "color", "column", "combine", "come",
    "comfort", "comic", "common", "company", "concert", "conduct", "confirm", "congress",
    "connect", "consider", "control", "convince", "cook", "cool", "copper", "copy", "coral",
    "core", "corn", "correct", "cost", "cotton", "couch", "country", "couple", "course",
    "cousin", "cover", "coyote", "crack", "cradle", "craft", "cram", "crane", "crash",
    "crater", "crawl", "crazy", "cream", "credit", "creek", "crew", "cricket", "crime",
    "crisp", "critic", "crop", "cross", "crouch", "crowd", "crucial", "cruel", "cruise",
    "crumble", "crunch", "crush", "cry", "crystal", "cube", "culture", "cup", "cupboard",
    "curious", "current", "curtain", "curve", "cushion", "custom", "cute", "cycle", "dad",
    "damage", "damp", "dance", "danger", "daring", "dash", "daughter", "dawn", "day", "deal",
    "debate", "debris", "decade", "december", "decide", "decline", "decorate", "decrease",
    "deer", "defense", "define", "defy", "degree", "delay", "deliver", "demand", "demise",
    "denial", "dentist", "deny", "depart", "depend", "deposit", "depth", "deputy", "derive",
    "describe", "desert", "design", "desk", "despair", "destroy", "detail", "detect",
    "develop", "device", "devote", "diagram", "dial", "diamond", "diary", "dice", "diesel",
    "diet", "differ", "digital", "dignity", "dilemma", "dinner", "dinosaur", "direct", "dirt",
    "disagree", "discover", "disease", "dish", "dismiss", "disorder", "display", "distance",
    "divert", "divide", "divorce", "dizzy", "doctor", "document", "dog", "doll", "dolphin",
    "domain", "donate", "donkey", "donor", "door", "dose", "double", "dove", "draft", "dragon",
    "drama", "drastic", "draw", "dream", "dress", "drift", "drill", "drink", "drip", "drive",
    "drop", "drum", "dry", "duck", "dumb", "dune", "during", "dust", "dutch", "duty", "dwarf",
    "dynamic", "eager", "eagle", "early", "earn", "earth", "easily", "east", "easy", "echo",
    "ecology", "economy", "edge", "edit", "educate", "effort", "egg", "eight", "either",
    "elbow", "elder", "electric", "elegant", "element", "elephant", "elevator", "elite",
    "else", "embark", "embody", "embrace", "emerge", "emotion", "employ", "empower", "empty",
    "enable", "enact", "end", "endless", "endorse", "enemy", "energy", "enforce", "engage",
    "engine", "enhance", "enjoy", "enlist", "enough", "enrich", "enroll", "ensure", "enter",
    "entire", "entry", "envelope", "episode", "equal", "equip", "era", "erase", "erode",
    "erosion", "error", "erupt", "escape", "essay", "essence", "estate", "eternal", "ethics",
    "evidence", "evil", "evoke", "evolve", "exact", "example", "excess", "exchange", "excite",
    "exclude", "excuse", "execute", "exercise", "exhaust", "exhibit", "exile", "exist", "exit",
    "exotic", "expand", "expect", "expire", "explain", "expose", "express", "extend", "extra",
    "eye", "eyebrow", "fabric", "face", "faculty", "fade", "faint", "faith", "fall", "false",
    "fame", "family", "famous", "fan", "fancy", "fantasy", "farm", "fashion", "fat", "fatal",
    "father", "fatigue", "fault", "favorite", "feature", "february", "federal", "fee", "feed",
    "feel", "female", "fence", "festival", "fetch", "fever", "few", "fiber", "fiction",
    "field", "figure", "file", "film", "filter", "final", "find", "fine", "finger", "finish",
    "fire", "firm", "first", "fiscal", "fish", "fit", "fitness", "fix", "flag", "flame",
    "flash", "flat", "flavor", "flee", "flight", "flip", "float", "flock", "floor", "flower",
    "fluid", "flush", "fly", "foam", "focus", "fog", "foil", "fold", "follow", "food", "foot",
    "force", "forest", "forget", "fork", "fortune", "forum", "forward", "fossil", "foster",
    "found", "fox", "fragile", "frame", "frequent", "fresh", "friend", "fringe", "frog",
    "front", "frost", "frown", "frozen", "fruit", "fuel", "fun", "funny", "furnace", "fury",
    "future", "gadget", "gain", "galaxy", "gallery", "game", "gap", "garage", "garbage",
    "garden", "garlic", "garment", "gas", "gasp", "gate", "gather", "gauge", "gaze", "general",
    "genius", "genre", "gentle", "genuine", "gesture", "ghost", "giant", "gift", "giggle",
    "ginger", "giraffe", "girl", "give", "glad", "glance", "glare", "glass", "glide",
    "glimpse", "globe", "gloom", "glory", "glove", "glow", "glue", "goat", "goddess", "gold",
    "good", "goose", "gorilla", "gospel", "gossip", "govern", "gown", "grab", "grace", "grain",
    "grant", "grape", "grass", "gravity", "great", "green", "grid", "grief", "grit", "grocery",
    "group", "grow", "grunt", "guard", "guess", "guide", "guilt", "guitar", "gun", "gym",
    "habit", "hair", "half", "hammer", "hamster", "hand", "happy", "harbor", "hard", "harsh",
    "harvest", "hat", "have", "hawk", "hazard", "head", "health", "heart", "heavy", "hedgehog",
    "height", "hello", "helmet", "help", "hen", "hero", "hidden", "high", "hill", "hint",
    "hip", "hire", "history", "hobby", "hockey", "hold", "hole", "holiday", "hollow", "home",
    "honey", "hood", "hope", "horn", "horror", "horse", "hospital", "host", "hotel", "hour",
    "hover", "hub", "huge", "human", "humble", "humor", "hundred", "hungry", "hunt", "hurdle",
    "hurry", "hurt", "husband", "hybrid", "ice", "icon", "idea", "identify", "idle", "ignore",
    "ill", "illegal", "illness", "image", "imitate", "immense", "immune", "impact", "impose",
    "improve", "impulse", "inch", "include", "income", "increase", "index", "indicate",
    "indoor", "industry", "infant", "inflict", "inform", "inhale", "inherit", "initial",
    "inject", "injury", "inmate", "inner", "innocent", "input", "inquiry", "insane", "insect",
    "inside", "inspire", "install", "intact", "interest", "into", "invest", "invite",
    "involve", "iron", "island", "isolate", "issue", "item", "ivory", "jacket", "jaguar",
    "jar", "jazz", "jealous", "jeans", "jelly", "jewel", "job", "join", "joke", "journey",
    "joy", "judge", "juice", "jump", "jungle", "junior", "junk", "just", "kangaroo", "keen",
    "keep", "ketchup", "key", "kick", "kid", "kidney", "kind", "kingdom", "kiss", "kit",
    "kitchen", "kite", "kitten", "kiwi", "knee", "knife", "knock", "know", "lab", "label",
    "labor", "ladder", "lady", "lake", "lamp", "language", "laptop", "large", "later", "latin",
    "laugh", "laundry", "lava", "law", "lawn", "lawsuit", "layer", "lazy", "leader", "leaf",
    "learn", "leave", "lecture", "left", "leg", "legal", "legend", "leisure", "lemon", "lend",
    "length", "lens", "leopard", "lesson", "letter", "level", "liar", "liberty", "library",
    "license", "life", "lift", "light", "like", "limb", "limit", "link", "lion", "liquid",
    "list", "little", "live", "lizard", "load", "loan", "lobster", "local", "lock", "logic",
    "lonely", "long", "loop", "lottery", "loud", "lounge", "love", "loyal", "lucky", "luggage",
    "lumber", "lunar", "lunch", "luxury", "lyrics", "machine", "mad", "magic", "magnet",
    "maid", "mail", "main", "major", "make", "mammal", "man", "manage", "mandate", "mango",
    "mansion", "manual", "maple", "marble", "march", "margin", "marine", "market", "marriage",
    "mask", "mass", "master", "match", "material", "math", "matrix", "matter", "maximum",
    "maze", "meadow", "mean", "measure", "meat", "mechanic", "medal", "media", "melody",
    "melt", "member", "memory", "mention", "menu", "mercy", "merge", "merit", "merry", "mesh",
    "message", "metal", "method", "middle", "midnight", "milk", "million", "mimic", "mind",
    "minimum", "minor", "minute", "miracle", "mirror", "misery", "miss", "mistake", "mix",
    "mixed", "mixture", "mobile", "model", "modify", "mom", "moment", "monitor", "monkey",
    "monster", "month", "moon", "moral", "more", "morning", "mosquito", "mother", "motion",
    "motor", "mountain", "mouse", "move", "movie", "much", "muffin", "mule", "multiply",
    "muscle", "museum", "mushroom", "music", "must", "mutual", "myself", "mystery", "myth",
    "naive", "name", "napkin", "narrow", "nasty", "nation", "nature", "near", "neck", "need",
    "negative", "neglect", "neither", "nephew", "nerve", "nest", "net", "network", "neutral",
    "never", "news", "next", "nice", "night", "noble", "noise", "nominee", "noodle", "normal",
    "north", "nose", "notable", "note", "nothing", "notice", "novel", "now", "nuclear",
    "number", "nurse", "nut", "oak", "obey", "object", "oblige", "obscure", "observe",
    "obtain", "obvious", "occur", "ocean", "october", "odor", "off", "offer", "office",
    "often", "oil", "okay", "old", "olive", "olympic", "omit", "once", "one", "onion",
    "online", "only", "open", "opera", "opinion", "oppose", "option", "orange", "orbit",
    "orchard", "order", "ordinary", "organ", "orient", "original", "orphan", "ostrich",
    "other", "outdoor", "outer", "output", "outside", "oval", "oven", "over", "own", "owner",
    "oxygen", "oyster", "ozone", "pact", "paddle", "page", "pair", "palace", "palm", "panda",
    "panel", "panic", "panther", "paper", "parade", "parent", "park", "parrot", "party",
    "pass", "patch", "path", "patient", "patrol", "pattern", "pause", "pave", "payment",
    "peace", "peanut", "pear", "peasant", "pelican", "pen", "penalty", "pencil", "people",
    "pepper", "perfect", "permit", "person", "pet", "phone", "photo", "phrase", "physical",
    "piano", "picnic", "picture", "piece", "pig", "pigeon", "pill", "pilot", "pink", "pioneer",
    "pipe", "pistol", "pitch", "pizza", "place", "planet", "plastic", "plate", "play",
    "please", "pledge", "pluck", "plug", "plunge", "poem", "poet", "point", "polar", "pole",
    "police", "pond", "pony", "pool", "popular", "portion", "position", "possible", "post",
    "potato", "pottery", "poverty", "powder", "power", "practice", "praise", "predict",
    "prefer", "prepare", "present", "pretty", "prevent", "price", "pride", "primary", "print",
    "priority", "prison", "private", "prize", "problem", "process", "produce", "profit",
    "program", "project", "promote", "proof", "property", "prosper", "protect", "proud",
    "provide", "public", "pudding", "pull", "pulp", "pulse", "pumpkin", "punch", "pupil",
    "puppy", "purchase", "purity", "purpose", "purse", "push", "put", "puzzle", "pyramid",
    "quality", "quantum", "quarter", "question", "quick", "quit", "quiz", "quote", "rabbit",
    "raccoon", "race", "rack", "radar", "radio", "rail", "rain", "raise", "rally", "ramp",
    "ranch", "random", "range", "rapid", "rare", "rate", "rather", "raven", "raw", "razor",
    "ready", "real", "reason", "rebel", "rebuild", "recall", "receive", "recipe", "record",
    "recycle", "reduce", "reflect", "reform", "refuse", "region", "regret", "regular",
    "reject", "relax", "release", "relief", "rely", "remain", "remember", "remind", "remove",
    "render", "renew", "rent", "reopen", "repair", "repeat", "replace", "report", "require",
    "rescue", "resemble", "resist", "resource", "response", "result", "retire", "retreat",
    "return", "reunion", "reveal", "review", "reward", "rhythm", "rib", "ribbon", "rice",
    "rich", "ride", "ridge", "rifle", "right", "rigid", "ring", "riot", "ripple", "risk",
    "ritual", "rival", "river", "road", "roast", "robot", "robust", "rocket", "romance",
    "roof", "rookie", "room", "rose", "rotate", "rough", "round", "route", "royal", "rubber",
    "rude", "rug", "rule", "run", "runway", "rural", "sad", "saddle", "sadness", "safe",
    "sail", "salad", "salmon", "salon", "salt", "salute", "same", "sample", "sand", "satisfy",
    "satoshi", "sauce", "sausage", "save", "say", "scale", "scan", "scare", "scatter", "scene",
    "scheme", "school", "science", "scissors", "scorpion", "scout", "scrap", "screen",
    "script", "scrub", "sea", "search", "season", "seat", "second", "secret", "section",
    "security", "seed", "seek", "segment", "select", "sell", "seminar", "senior", "sense",
    "sentence", "series", "service", "session", "settle", "setup", "seven", "shadow", "shaft",
    "shallow", "share", "shed", "shell", "sheriff", "shield", "shift", "shine", "ship",
    "shiver", "shock", "shoe", "shoot", "shop", "short", "shoulder", "shove", "shrimp",
    "shrug", "shuffle", "shy", "sibling", "sick", "side", "siege", "sight", "sign", "silent",
    "silk", "silly", "silver", "similar", "simple", "since", "sing", "siren", "sister",
    "situate", "six", "size", "skate", "sketch", "ski", "skill", "skin", "skirt", "skull",
    "slab", "slam", "sleep", "slender", "slice", "slide", "slight", "slim", "slogan", "slot",
    "slow", "slush", "small", "smart", "smile", "smoke", "smooth", "snack", "snake", "snap",
    "sniff", "snow", "soap", "soccer", "social", "sock", "soda", "soft", "solar", "soldier",
    "solid", "solution", "solve", "someone", "song", "soon", "sorry", "sort", "soul", "sound",
    "soup", "source", "south", "space", "spare", "spatial", "spawn", "speak", "special",
    "speed", "spell", "spend", "sphere", "spice", "spider", "spike", "spin", "spirit", "split",
    "spoil", "sponsor", "spoon", "sport", "spot", "spray", "spread", "spring", "spy", "square",
    "squeeze", "squirrel", "stable", "stadium", "staff", "stage", "stairs", "stamp", "stand",
    "start", "state", "stay", "steak", "steel", "stem", "step", "stereo", "stick", "still",
    "sting", "stock", "stomach", "stone", "stool", "story", "stove", "strategy", "street",
    "strike", "strong", "struggle", "student", "stuff", "stumble", "style", "subject",
    "submit", "subway", "success", "such", "sudden", "suffer", "sugar", "suggest", "suit",
    "summer", "sun", "sunny", "sunset", "super", "supply", "supreme", "sure", "surface",
    "surge", "surprise", "surround", "survey", "suspect", "sustain", "swallow", "swamp",
    "swap", "swarm", "swear", "sweet", "swift", "swim", "swing", "switch", "sword", "symbol",
    "symptom", "syrup", "system", "table", "tackle", "tag", "tail", "talent", "talk", "tank",
    "tape", "target", "task", "taste", "tattoo", "taxi", "teach", "team", "tell", "ten",
    "tenant", "tennis", "tent", "term", "test", "text", "thank", "that", "theme", "then",
    "theory", "there", "they", "thing", "this", "thought", "three", "thrive", "throw", "thumb",
    "thunder", "ticket", "tide", "tiger", "tilt", "timber", "time", "tiny", "tip", "tired",
    "tissue", "title", "toast", "tobacco", "today", "toddler", "toe", "together", "toilet",
    "token", "tomato", "tomorrow", "tone", "tongue", "tonight", "tool", "tooth", "top",
    "topic", "topple", "torch", "tornado", "tortoise", "toss", "total", "tourist", "toward",
    "tower", "town", "toy", "track", "trade", "traffic", "tragic", "train", "transfer", "trap",
    "trash", "travel", "tray", "treat", "tree", "trend", "trial", "tribe", "trick", "trigger",
    "trim", "trip", "trophy", "trouble", "truck", "true", "truly", "trumpet", "trust", "truth",
    "try", "tube", "tuition", "tumble", "tuna", "tunnel", "turkey", "turn", "turtle", "twelve",
    "twenty", "twice", "twin", "twist", "two", "type", "typical", "ugly", "umbrella", "unable",
    "unaware", "uncle", "uncover", "under", "undo", "unfair", "unfold", "unhappy", "uniform",
    "unique", "unit", "universe", "unknown", "unlock", "until", "unusual", "unveil", "update",
    "upgrade", "uphold", "upon", "upper", "upset", "urban", "urge", "usage", "use", "used",
    "useful", "useless", "usual", "utility", "vacant", "vacuum", "vague", "valid", "valley",
    "valve", "van", "vanish", "vapor", "various", "vast", "vault", "vehicle", "velvet",
    "vendor", "venture", "venue", "verb", "verify", "version", "very", "vessel", "veteran",
    "viable", "vibrant", "vicious", "victory", "video", "view", "village", "vintage", "violin",
    "virtual", "virus", "visa", "visit", "visual", "vital", "vivid", "vocal", "voice", "void",
    "volcano", "volume", "vote", "voyage", "wage", "wagon", "wait", "walk", "wall", "walnut",
    "want", "warfare", "warm", "warrior", "wash", "wasp", "waste", "water", "wave", "way",
    "wealth", "weapon", "wear", "weasel", "weather", "web", "wedding", "weekend", "weird",
    "welcome", "west", "wet", "whale", "what", "wheat", "wheel", "when", "where", "whip",
    "whisper", "wide", "width", "wife", "wild", "will", "win", "window", "wine", "wing",
    "wink", "winner", "winter", "wire", "wisdom", "wise", "wish", "witness", "wolf", "woman",
    "wonder", "wood", "wool", "word", "work", "world", "worry", "worth", "wrap", "wreck",
    "wrestle", "wrist", "write", "wrong", "yard", "year", "yellow", "you", "young", "youth",
    "zebra", "zero", "zone", "zoo",
};

test "assemble: canonical all-zero 256-bit entropy vector" {
    var data: [33]u8 = [_]u8{0} ** 33;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data[0..32], &digest, .{});
    data[32] = digest[0];
    var out: [max_mnemonic_len]u8 = undefined;
    const m = try assemble(&data, 24, &out);
    try std.testing.expectEqualStrings(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon " ++
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon " ++
            "abandon abandon abandon art",
        m,
    );
}

test "assemble: canonical all-zero 128-bit entropy vector" {
    var data: [17]u8 = [_]u8{0} ** 17;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data[0..16], &digest, .{});
    data[16] = digest[0];
    var out: [max_mnemonic_len]u8 = undefined;
    const m = try assemble(&data, 12, &out);
    try std.testing.expectEqualStrings(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        m,
    );
}

test "generate: 24 words, distinct from a second draw, all in the wordlist" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var a: [max_mnemonic_len]u8 = undefined;
    var b: [max_mnemonic_len]u8 = undefined;
    const ma = try generate(io, 24, &a);
    const mb = try generate(io, 24, &b);
    defer {
        @memset(&a, 0);
        @memset(&b, 0);
    }

    // 24 space-separated words, each a real wordlist entry.
    var it = std.mem.splitScalar(u8, ma, ' ');
    var count: usize = 0;
    while (it.next()) |word| {
        count += 1;
        var found = false;
        for (wordlist) |w| {
            if (std.mem.eql(u8, w, word)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(@as(usize, 24), count);
    // Two CSPRNG draws must not collide.
    try std.testing.expect(!std.mem.eql(u8, ma, mb));
}

test "generate: rejects unsupported word counts" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var out: [max_mnemonic_len]u8 = undefined;
    try std.testing.expectError(error.UnsupportedWordCount, generate(threaded.io(), 18, &out));
}

test "validate: accepts the canonical BIP39 vectors at every supported length" {
    // From bitcoin/bips bip-0039 test vectors (English). These are the phrases a
    // real restore is handed, so the packing has to agree with them exactly.
    const good = [_][]const u8{
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "legal winner thank year wave sausage worth useful legal winner thank yellow",
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon address",
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon agent",
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon admit",
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
        "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
        "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote",
    };
    for (good) |m| try validate(m);
}

test "validate: names the three ways a typed phrase goes wrong" {
    // Wrong length — 11 words.
    try std.testing.expectError(error.BadWordCount, validate(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
    ));
    // A word that isn't in the list at all (the plain typo).
    try std.testing.expectError(error.UnknownWord, validate(
        "abandonn abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
    ));
    // Every word real and the length right, but the checksum fails — the last
    // word swapped for another valid one. This is the case a wordlist check
    // alone can't catch, and divid only reports it a daemon-start later.
    try std.testing.expectError(error.BadChecksum, validate(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon",
    ));
    // Two words transposed — also a checksum failure.
    try std.testing.expectError(error.BadChecksum, validate(
        "legal winner thank year wave sausage worth useful legal winner yellow thank",
    ));
    // Too many words.
    try std.testing.expectError(error.BadWordCount, validate(
        "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote",
    ));
}

test "validate: round-trips whatever generate produces" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var out: [max_mnemonic_len]u8 = undefined;
    for (0..16) |_| {
        try validate(try generate(io, 24, &out));
        try validate(try generate(io, 12, &out));
    }
}

test "looksLikeHexSeed separates a raw seed from a mnemonic" {
    // The canonical seed for "abandon…about", as dumphdinfo reports it.
    const hex = "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4";
    try std.testing.expect(looksLikeHexSeed(hex));
    // Upper case is still hex.
    var upper: [hex_seed_len]u8 = undefined;
    for (hex, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    try std.testing.expect(looksLikeHexSeed(&upper));

    // A mnemonic is never mistaken for one, whatever its length.
    try std.testing.expect(!looksLikeHexSeed(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
    ));
    // Right length, but not hex ('z').
    try std.testing.expect(!looksLikeHexSeed("z" ** hex_seed_len));
    // Hex, but the wrong length — a truncated paste must not read as a seed.
    try std.testing.expect(!looksLikeHexSeed(hex[0 .. hex_seed_len - 1]));
    try std.testing.expect(!looksLikeHexSeed(""));
}
