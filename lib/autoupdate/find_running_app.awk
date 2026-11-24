function flush_entry(    bp, target_clean, is_path_target, is_top_level_app,
                         target_lc, target_no_ext, base, base_lc, base_no_ext,
                         bid_lc, name_lc, matched, score) {
  if (!in_entry || pid == "") return

  bp = bundle_path
  sub(/\/+$/, "", bp)

  target_clean = target
  sub(/\/+$/, "", target_clean)

  is_path_target = (substr(target_clean, 1, 1) == "/")
  matched = 0
  score = 0

  if (is_path_target) {
    if (bp == target_clean) {
      matched = 1
      score = 10
    } else if (tolower(bp) == tolower(target_clean)) {
      matched = 1
      score = 5
    }
  } else {
    target_lc = tolower(target_clean)
    target_no_ext = target_lc
    sub(/\.app$/, "", target_no_ext)

    is_top_level_app = (tolower(bp) ~ /\.app$/ && tolower(bp) !~ /\.app\//)

    base = bp
    sub(/^.*\//, "", base)
    base_lc = tolower(base)
    base_no_ext = base_lc
    sub(/\.app$/, "", base_no_ext)

    bid_lc = tolower(bundle_id)
    name_lc = tolower(name)

    if (bid_lc != "" && bid_lc == target_lc) {
      matched = 1
      score = 8
    } else if (is_top_level_app && base_no_ext != "" && base_no_ext == target_no_ext) {
      matched = 1
      score = 6
    } else if (is_top_level_app && name_lc != "" && name_lc == target_no_ext) {
      matched = 1
      score = 4
    }
  }

  if (matched) {
    if (app_type == "Foreground") {
      score += 3
    } else if (app_type == "UIElement") {
      score += 2
    } else {
      score += 1
    }

    if (score > best_score) {
      best_score = score
      best_pid = pid
      best_bid = bundle_id
      best_bp = bundle_path
    }
  }
}

BEGIN {
  target = ENVIRON["TARGET_APP"]
  in_entry = 0
  best_score = 0
  best_pid = ""
  best_bid = ""
  best_bp = ""
}

/^[[:space:]]*[0-9]+\) ".*" ASN:/ {
  flush_entry()
  name = $0
  sub(/^[[:space:]]*[0-9]+\) "/, "", name)
  sub(/" ASN:.*$/, "", name)
  bundle_id = ""
  bundle_path = ""
  pid = ""
  app_type = ""
  in_entry = 1
  next
}

in_entry && /^[[:space:]]*bundleID="/ {
  bundle_id = $0
  sub(/^[[:space:]]*bundleID="/, "", bundle_id)
  sub(/"[[:space:]]*$/, "", bundle_id)
  next
}

in_entry && /^[[:space:]]*bundle path="/ {
  bundle_path = $0
  sub(/^[[:space:]]*bundle path="/, "", bundle_path)
  sub(/"[[:space:]]*$/, "", bundle_path)
  next
}

in_entry && /^[[:space:]]*pid = [0-9]+/ {
  line = $0
  sub(/^[[:space:]]*pid = /, "", line)
  sub(/[^0-9].*$/, "", line)
  pid = line
  if ($0 ~ /type="[^"]*"/) {
    t = $0
    sub(/^.*type="/, "", t)
    sub(/".*$/, "", t)
    app_type = t
  }
  next
}

END {
  flush_entry()
  if (best_score > 0) {
    printf "%s\t%s\t%s\n", best_pid, best_bid, best_bp
  }
}
