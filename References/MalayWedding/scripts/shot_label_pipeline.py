"""Shot-by-shot timeline labeling of Malay wedding reference videos.
For each video: detect cuts, extract middle frame per shot, classify with Gemini,
emit one JSONL record per shot (append only). Open taxonomy -- create new
moment types when existing 15 don't fit."""
import subprocess, json, os, sys, time, base64, urllib.request, traceback
from pathlib import Path
from collections import Counter

# --- config ---
# Set OPENROUTER_API_KEY in your environment; never hardcode the key.
OR_KEY = os.environ.get("OPENROUTER_API_KEY", "")
if not OR_KEY:
    sys.exit("Set OPENROUTER_API_KEY in your environment before running.")
BASE = Path(r"C:\Users\AriffHakimiChik\video-editor")
REF_DIR = BASE / "References" / "MalayWedding"
JSONL_PATH = REF_DIR / "metadata" / "references_malay_wedding.jsonl"
AI_TAX_PATH = BASE / "AI-reference" / "taxonomy_malay_wedding.json"
AI_JSONL_PATH = BASE / "AI-reference" / "references_malay_wedding.jsonl"
TEMP = REF_DIR / "_temp_shotlabel"
PROGRESS_FILE = REF_DIR / "_temp_vision" / "shot_progress.json"
LOGFILE = TEMP / "shotlabel.log"
os.makedirs(TEMP, exist_ok=True)
os.makedirs(REF_DIR / "_temp_vision", exist_ok=True)

# --- existing 15 controlled moments ---
EXISTING_15 = {
    "akad_nikah": "ceremony", "ring_exchange": "ceremony",
    "bride_prep": "preparation", "groom_prep": "preparation",
    "hantaran_detail": "scene", "salam_family": "family",
    "family_portrait": "family", "guest_reaction": "family",
    "couple_portrait": "scene", "venue_establishing": "scene",
    "decor_detail": "scene", "pelamin": "celebration",
    "reception": "celebration", "makan_beradab": "celebration",
    "exit_or_closing": "scene"
}

# --- new moments discovered during labeling (agent adds here) ---
NEW_MOMENTS = {}  # {moment_type: category}

# --- audio defaults per moment ---
AUDIO_DEFAULTS = {
    "akad_nikah": "crucial", "ring_exchange": "crucial",
    "bride_prep": "ambient", "groom_prep": "ambient",
    "hantaran_detail": "replaceable", "salam_family": "crucial",
    "family_portrait": "replaceable", "guest_reaction": "ambient",
    "couple_portrait": "replaceable", "venue_establishing": "replaceable",
    "decor_detail": "replaceable", "pelamin": "replaceable",
    "reception": "ambient", "makan_beradab": "ambient",
    "exit_or_closing": "replaceable"
}

AVOID_DEFAULTS = {
    "akad_nikah": ["shaky_camera","zoom_in_out","crowd_blocking"],
    "ring_exchange": ["shaky_camera","blocked_view"],
    "bride_prep": ["shaky_camera","backlit_faces"],
    "groom_prep": ["shaky_camera","blocked_view"],
    "hantaran_detail": ["shaky_camera","backlit_faces"],
    "salam_family": ["back_of_head_only","out_of_focus","crowd_blocking"],
    "family_portrait": ["crowd_blocking","backlit_faces"],
    "guest_reaction": ["back_of_head_only"],
    "couple_portrait": ["backlit_faces","blocked_view"],
    "venue_establishing": ["shaky_camera","fast_panning","overexposed"],
    "decor_detail": ["shaky_camera","overexposed"],
    "pelamin": ["flashed_photography","crowd_blocking","backlit_faces"],
    "reception": ["shaky_camera","backlit_faces","flashed_photography"],
    "makan_beradab": ["shaky_camera","blocked_view"],
    "exit_or_closing": ["shaky_camera","backlit_faces"]
}

# --- helpers ---
def log(m):
    print(m, flush=True)
    with open(LOGFILE, "a", encoding="utf-8") as f:
        f.write(str(m) + "\n")
        f.flush()

def save_progress(done_vids):
    with open(PROGRESS_FILE, "w") as f:
        json.dump({"done": sorted(done_vids)}, f)

def load_progress():
    if PROGRESS_FILE.exists():
        with open(PROGRESS_FILE) as f:
            return set(json.load(f).get("done", []))
    return set()

def merge_short_shots(shots, min_duration=1.0):
    """Merge shots shorter than min_duration into the previous shot."""
    if not shots:
        return shots
    merged = [shots[0]]
    for ss, se in shots[1:]:
        last_s, last_e = merged[-1]
        duration = se - ss
        if duration < min_duration:
            # Extend previous shot
            merged[-1] = (last_s, se)
        else:
            merged.append((ss, se))
    return merged

def detect_shots(video_path):
    """Detect shot boundaries. Returns list of (start_sec, end_sec)."""
    try:
        from scenedetect import detect, ContentDetector
        scenes = detect(video_path, ContentDetector(threshold=42))
        if not scenes:
            return []
        result = []
        for start, end in scenes:
            s = start.seconds if hasattr(start, 'seconds') else start.get_seconds()
            e = end.seconds if hasattr(end, 'seconds') else end.get_seconds()
            if e - s >= 0.3:
                result.append((s, e))
        result = merge_short_shots(result)
        return result
    except Exception as e:
        log(f"   scenedetect failed: {e}")
        return []

def fallback_sample_every_2s(duration):
    """Sample every 2 seconds as individual shots when scenedetect fails."""
    shots = []
    t = 0.0
    while t < duration:
        end = min(t + 2.0, duration)
        shots.append((t, end))
        t = end
    return shots

def extract_middle_frame(video_path, shot_start, shot_end, output_path):
    """Extract frame from the middle of a shot."""
    mid = (shot_start + shot_end) / 2
    r = subprocess.run(["ffmpeg","-y","-ss",str(mid),"-i",str(video_path),"-vframes","1","-vf","scale=480:-1","-q:v","3",str(output_path)], capture_output=True, text=True, timeout=30)
    return output_path.exists()

def classify_batch(frames_batch, shot_indices, video_title):
    """Send batch of frames to Gemini, get classifications back."""
    url = "https://openrouter.ai/api/v1/chat/completions"
    existing_list = ", ".join(sorted(EXISTING_15.keys()))
    content = [{"type": "text", "text": f"You're analyzing shots from a Malay wedding highlight video: '{video_title}'.\nBelow are {len(frames_batch)} frames, each from a different shot in order.\n\nFor EACH frame, identify the wedding moment shown. STRICTLY use one of the EXISTING types below when possible. Only create a NEW type if the shot genuinely doesn't fit any existing type.\n\nEXISTING types (prefer these):\n{existing_list}\n\nEXAMPLES of when existing types apply:\n- bride getting makeup/hair: bride_prep (NOT bride_moment, bride_processional, bride_entrance)\n- groom getting dressed: groom_prep (NOT groom_arrival, groom_entrance)\n- family group photoing: family_portrait (NOT group_photo)\n- ijab kabul / vows: akad_nikah (NOT wedding_vows, vows_or_letters)\n- guests mingling: reception (NOT guest_interaction)\n- songs/entertainment: reception (NOT live_music)\n- couple posing for camera: couple_portrait (NOT couple_entrance)\n- black / fade frames: ignore or label as editorial_transition\n\nReturn a JSON array with {len(frames_batch)} entries, one per frame in order:\n[{{\"shotIndex\": <int>, \"primaryMoment\": \"type\", \"shotQualities\": [\"stable_camera\",\"clear_faces\"], \"audioImportance\": \"crucial|replaceable|ambient\", \"sceneDescription\": \"brief description\", \"confidence\": 0.0-1.0}},...]" }]
    for i, (fp, sidx) in enumerate(zip(frames_batch, shot_indices)):
        with open(fp, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        content.append({"type": "text", "text": f"[Shot {sidx}]:"})
        content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}})
    
    payload = {"model": "google/gemini-2.5-flash-lite", "messages": [{"role": "user", "content": content}], "max_tokens": 3000, "temperature": 0.1}
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type":"application/json","Authorization":f"Bearer {OR_KEY}"}, method="POST")
    
    for retry in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                result = json.loads(resp.read().decode())
                text = result.get("choices",[{}])[0].get("message",{}).get("content","")
                start = text.find("[")
                end = text.rfind("]") + 1
                if start >= 0 and end > start:
                    arr = json.loads(text[start:end])
                    return arr
                log(f"   DEBUG: response had no JSON array: {text[:200]}")
                return None
        except urllib.error.HTTPError as e:
            err_body = e.read().decode()[:300] if hasattr(e, 'read') else ''
            log(f"   DEBUG HTTP {e.code}: {err_body}")
            if "429" in str(e.code):
                time.sleep(10 * (retry + 1))
                continue
            return None
        except Exception as ex:
            log(f"   DEBUG exception: {ex}")
            return None
    return None

def normalize_moment(m):
    """Return validated moment type, creating new one if needed."""
    m = m.strip().lower().replace(" ", "_")
    if m in EXISTING_15:
        return m
    # New moment -- register it
    if m not in NEW_MOMENTS:
        # Guess category (can be hand-corrected later)
        if any(kw in m for kw in ["prep","hair","makeup","dress","suit","gown"]):
            cat = "preparation"
        elif any(kw in m for kw in ["nikah","akad","solemn","vow","ring","exchange"]):
            cat = "ceremony"
        elif any(kw in m for kw in ["family","salam","portrait","guest","reaction","cry","hug"]):
            cat = "family"
        elif any(kw in m for kw in ["party","dance","cake","cut","toast","reception","feast","makan","pelamin","sanding"]):
            cat = "celebration"
        else:
            cat = "scene"
        NEW_MOMENTS[m] = cat
        log(f"   ** NEW MOMENT: {m} (category: {cat})")
    return m

def build_shot_record(vid, detail, shot_idx, seq_hint, tc_start, tc_end, classification):
    """Build a single JSONL record for one shot."""
    moment = normalize_moment(classification.get("primaryMoment", "reception"))
    shot_quals = classification.get("shotQualities", ["stable_camera"])
    if not isinstance(shot_quals, list):
        shot_quals = ["stable_camera"]
    audio = classification.get("audioImportance", AUDIO_DEFAULTS.get(moment, "replaceable"))
    if audio not in ("crucial", "replaceable", "ambient"):
        audio = AUDIO_DEFAULTS.get(moment, "replaceable")
    conf = min(float(classification.get("confidence", 0.85)), 1.0)
    if conf < 0.7:
        return None
    avoid = AVOID_DEFAULTS.get(moment, ["shaky_camera", "backlit_faces"])
    scene_desc = classification.get("sceneDescription", "")
    cultural_notes = f"{scene_desc[:200]}" if scene_desc else f"Wedding shot of {moment}"
    
    return {
        "id": f"s_{vid}_{shot_idx}",
        "sourceVideoId": vid,
        "sourceURL": f"https://youtube.com/watch?v={vid}",
        "sourcePlatform": "youtube",
        "channel": detail.get("channel", "Blastphere Ventures"),
        "creatorName": detail.get("channel", "Blastphere Ventures"),
        "title": detail.get("title", ""),
        "duration": detail.get("duration", tc_end),
        "license": detail.get("license", "youtube_standard"),
        "permissionStatus": "usable_media",
        "primaryMoment": moment,
        "momentTypes": [moment],
        "momentSequenceHint": seq_hint,
        "timecodeStart": round(tc_start, 1),
        "timecodeEnd": round(tc_end, 1),
        "audioImportance": audio,
        "preferredShotQualities": shot_quals[:8],
        "avoidQualities": avoid,
        "culturalNotes": cultural_notes[:300],
        "labelConfidence": round(conf, 2),
        "visualVerificationMethod": "gemini_vision"
    }

def has_shot_records(vid, existing_jsonl_ids):
    """Check if vid already has shot-level records (id like vid_0, vid_1, etc.)."""
    for rid in existing_jsonl_ids:
        if rid.startswith(f"{vid}_") and rid[len(vid)+1:].isdigit():
            return True
    return False

def get_existing_ids(jsonl_path):
    """Read existing JSONL and return set of all record ids."""
    ids = set()
    if jsonl_path.exists():
        with open(jsonl_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    try:
                        r = json.loads(line)
                        ids.add(r.get("id", ""))
                    except: pass
    return ids

# ===== MAIN =====
log("=== Shot-by-shot timeline labeling pipeline ===")

# Step 1: Get list of videos to process
log("1. Getting video list...")
r = subprocess.run(["yt-dlp","--flat-playlist","--dump-json","--ignore-errors","--no-warnings","https://www.youtube.com/@blastphereventures4947/videos"], capture_output=True, text=True, timeout=120)
all_vids = [json.loads(l) for l in r.stdout.strip().split("\n") if l.strip()]
# Filter wedding (no BTS)
wedding_vids = [v for v in all_vids if not any(w in (v.get("title") or "").lower() for w in ["bts", "behind the scene"]) and any(w in (v.get("title") or "").lower() for w in ["wedding","nikah","akad","kawin","solemnization","reception","pelamin","sanding"])]
log(f"   Total on channel: {len(all_vids)}, Wedding (no BTS): {len(wedding_vids)}")

# Step 2: Check idempotency
done_vids = load_progress()
log(f"   Shot-progress done: {len(done_vids)}")

remaining = [v for v in wedding_vids if v.get("id") not in done_vids]
log(f"   Already done: {len(done_vids)}, Remaining: {len(remaining)}")

# Step 3: Process each remaining video
total_shot_records = 0
new_moments_found = set()

for idx, v in enumerate(remaining):
    vid = v.get("id")
    title = v.get("title", "?")
    
    try:
        log(f"\n[{idx+1}/{len(remaining)}] {vid}: {title[:60]}")
        
        # Download to temp
        video_path = TEMP / f"{vid}.mp4"
        dl = subprocess.run(["yt-dlp","-f","worstvideo+worstaudio","--merge-output-format","mp4","--no-warnings","--no-playlist","-o",str(video_path),f"https://youtube.com/watch?v={vid}"], capture_output=True, text=True, timeout=600)
        if not video_path.exists():
            log(f"   Download failed, skipping")
            done_vids.add(vid)
            save_progress(done_vids)
            continue
        
        # Get duration
        probe = subprocess.run(["ffprobe","-v","error","-show_entries","format=duration","-of","csv=p=0",str(video_path)], capture_output=True, text=True, timeout=15)
        duration = float(probe.stdout.strip() or 300)
        log(f"   Dur:{duration:.0f}s Size:{os.path.getsize(video_path)//1024}KB")
        
        # Detect shots
        shots = detect_shots(video_path)
        if not shots or len(shots) < 3:
            log(f"   Cuts:{len(shots) if shots else 0} -- falling back to 2s sampling")
            shots = fallback_sample_every_2s(duration)
        
        log(f"   Shots detected: {len(shots)}")
        
        # Get detail metadata once
        detail_r = subprocess.run(["yt-dlp","--dump-json","--ignore-errors","--no-warnings",f"https://youtube.com/watch?v={vid}"], capture_output=True, text=True, timeout=60)
        detail = {}
        if detail_r.stdout.strip():
            try: detail = json.loads(detail_r.stdout)
            except: pass
        detail.setdefault("channel", "Blastphere Ventures")
        detail.setdefault("title", title)
        detail.setdefault("duration", duration)
        detail.setdefault("license", "youtube_standard")
        
        # Extract middle frame from each shot
        frame_paths = []
        for si, (ss, se) in enumerate(shots):
            fp = TEMP / f"{vid}_shot{si}.jpg"
            if extract_middle_frame(video_path, ss, se, fp):
                frame_paths.append((fp, si))
        
        log(f"   Frames extracted: {len(frame_paths)}")
        
        # Classify in batches of 5
        batch_size = 5
        shot_records = []
        for bi in range(0, len(frame_paths), batch_size):
            batch = frame_paths[bi:bi+batch_size]
            fps = [b[0] for b in batch]
            sidxs = [b[1] for b in batch]
            results = classify_batch(fps, sidxs, title)
            
            if results and isinstance(results, list):
                for result in results:
                    si = result.get("shotIndex")
                    if si is None:
                        continue
                    # Find the corresponding shot timecodes
                    idx_in_batch = sidxs.index(si) if si in sidxs else -1
                    if idx_in_batch >= 0 and si < len(shots):
                        ss, se = shots[si]
                        rec = build_shot_record(vid, detail, si, si, ss, se, result)
                        if rec:
                            shot_records.append(rec)
                            if rec["primaryMoment"] not in EXISTING_15:
                                new_moments_found.add(rec["primaryMoment"])
            else:
                log(f"   Batch {bi//batch_size}: Gemini returned no results")
            
            # Rate limit
            if bi + batch_size < len(frame_paths):
                time.sleep(1.5)
        
        log(f"   Shot records: {len(shot_records)}")
        
        # Append to JSONL
        if shot_records:
            for out_path in [JSONL_PATH, AI_JSONL_PATH]:
                with open(out_path, "a", encoding="utf-8") as f:
                    for rec in shot_records:
                        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
                        f.flush()
            total_shot_records += len(shot_records)
        
        done_vids.add(vid)
        save_progress(done_vids)
        
        # Cleanup
        if video_path.exists(): video_path.unlink()
        for fp, _ in frame_paths:
            if fp.exists(): fp.unlink()
        
    except Exception as e:
        log(f"   CRASH on {vid}: {str(e)[:150]}")
        traceback.print_exc()
        done_vids.add(vid)
        save_progress(done_vids)
        for f in TEMP.glob(f"{vid}*"):
            try: f.unlink()
            except: pass
    
    if idx < len(remaining) - 1:
        time.sleep(2)

# Step 4: Update taxonomy with new moment types
log(f"\n=== Taxonomy update ===")
if NEW_MOMENTS:
    log(f"New moment types created ({len(NEW_MOMENTS)}):")
    for m, cat in sorted(NEW_MOMENTS.items()):
        log(f"  - {m}: {cat}")
    
    # Read existing taxonomy
    taxonomy = {}
    if AI_TAX_PATH.exists():
        with open(AI_TAX_PATH, "r", encoding="utf-8") as f:
            taxonomy = json.load(f)
    
    if "momentCategories" not in taxonomy:
        taxonomy["momentCategories"] = {}
    
    for m, cat in NEW_MOMENTS.items():
        taxonomy["momentCategories"][m] = cat
    
    # Update version
    taxonomy["version"] = taxonomy.get("version", "1.0")
    if isinstance(taxonomy["version"], str):
        parts = taxonomy["version"].split(".")
        try:
            taxonomy["version"] = f"{parts[0]}.{int(parts[1]) + 1}" if len(parts) >= 2 else f"{taxonomy['version']}.1"
        except:
            taxonomy["version"] = "1.3"
    taxonomy["totalShotRecords"] = taxonomy.get("totalShotRecords", 0) + total_shot_records
    
    with open(AI_TAX_PATH, "w", encoding="utf-8") as f:
        json.dump(taxonomy, f, indent=2, ensure_ascii=False)
    log(f"Taxonomy updated at {AI_TAX_PATH}")
else:
    log("No new moment types needed")

log(f"\n=== DONE ===")
log(f"Videos processed: {len(remaining)}")
log(f"Total shot records emitted: {total_shot_records}")
if NEW_MOMENTS:
    log(f"New moments created: {len(NEW_MOMENTS)}")
    for m, cat in sorted(NEW_MOMENTS.items()):
        log(f"  {m} ({cat})")
