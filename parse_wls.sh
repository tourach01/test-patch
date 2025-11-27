#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 patch1.zip [patch2.zip ...]" >&2
  exit 1
fi


find_readme_in_zip() {
  local zip="$1"

  zipinfo -1 "$zip" 2>/dev/null | \
    awk 'BEGIN{IGNORECASE=1}
         # Match README-like files
         /(^|\/)readme[^\/]*\.(txt|html?)$/ {
             path=$0
             n=split(path, arr, "/")
             ext_rank=9
             if (tolower(path) ~ /\.txt$/)          ext_rank=1
             else if (tolower(path) ~ /\.html?$/)   ext_rank=2
             printf "%03d %d %s\n", n, ext_rank, path
         }' | \
    sort | \
    head -n1 | \
    cut -d" " -f3-
}


detect_product_type() {
  local file="$1"
  local lower
  lower="$(tr '[:upper:]' '[:lower:]' < "$file")"

  if grep -q "oracle coherence" <<<"$lower"; then
    echo "Coherence"
  elif grep -Eqi 'readme file for[[:space:]]+opatch|^patch[[:space:]][0-9]+[[:space:]]*-[[:space:]]*opatch' <<<"$lower"; then
    echo "OPatch"
  elif grep -Eqi "oracle weblogic server|oracle wls" <<<"$lower"; then
    echo "WebLogic"
  elif grep -qi "opatch" <<<"$lower"; then
    echo "OPatch"
  else
    echo "Unknown"
  fi
}



extract_patch_name() {
  local file="$1"
  local line
  local pname pver

  line="$(grep -Ei '^[[:space:]]*Oracle.*README' "$file" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    echo "$line" | \
      sed -E 's/^[[:space:]]+//; s/[[:space:]]+README.*$//I'
    return 0
  fi


  line="$(grep -Ei 'README file for' "$file" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    echo "$line" | \
      sed -E 's/.*README file for[[:space:]]+//I; s/,.*$//'
    return 0
  fi


  pname="$(grep -Ei 'Product[[:space:]]+Patched' "$file" | head -n1 | \
           sed -E 's/.*Product[[:space:]]+Patched[[:space:]]*:[[:space:]]*//I; s/[[:space:]]+$//' || true)"

  pver="$(grep -Ei 'Product[[:space:]]+Version' "$file" | head -n1 | \
          grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"

  if [[ -n "$pname" && -n "$pver" ]]; then
    echo "$pname $pver"
    return 0
  elif [[ -n "$pname" ]]; then
    echo "$pname"
    return 0
  fi

  echo ""
}


extract_versions() {
  local file="$1"
  local ptype="$2"
  local full=""
  local major=""

  if [[ "$ptype" == "WebLogic" ]]; then
    # Exemple : "Product Version : 14.1.1.0.250910"
    local line
    line="$(grep -Ei 'Product Version' "$file" | head -n1 || true)"
    if [[ -n "$line" ]]; then
      full="$(echo "$line" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
    fi
  elif [[ "$ptype" == "Coherence" ]]; then
    # Exemple : "Oracle Coherence 14.1.2.0.4 README"
    local line
    line="$(grep -Ei 'Oracle Coherence' "$file" | head -n1 || true)"
    if [[ -n "$line" ]]; then
      full="$(echo "$line" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
    fi
  elif [[ "$ptype" == "OPatch" ]]; then
    # Exemple : "PATCH 28186730 - OPATCH 13.9.4.2.21 FOR ..."
    local line
    line="$(grep -Ei 'OPatch' "$file" | head -n1 || true)"
    if [[ -n "$line" ]]; then
      full="$(echo "$line" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)"
    fi
  fi

  # Fallback générique
  if [[ -z "$full" ]]; then
    full="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' "$file" | head -n1 || true)"
  fi

  if [[ -n "$full" ]]; then
    # major = 4 premiers blocs
    IFS='.' read -r v1 v2 v3 v4 _ <<<"$full"
    if [[ -n "${v1:-}" && -n "${v2:-}" && -n "${v3:-}" && -n "${v4:-}" ]]; then
      major="${v1}.${v2}.${v3}.${v4}"
    fi
  fi

  echo "$full" "$major"
}


normalize_ddmonyy_to_month_year() {
  local raw_date="$1"
  local dd mon yy mon_l month year

  IFS='-/' read -r dd mon yy <<<"$raw_date"

  if [[ -z "${dd:-}" || -z "${mon:-}" || -z "${yy:-}" ]]; then
    echo ""
    return 0
  fi

  mon_l="$(echo "$mon" | tr '[:upper:]' '[:lower:]')"

  case "${mon_l:0:3}" in
    jan|1)  month="January" ;;
    feb|2)  month="February" ;;
    mar|3)  month="March" ;;
    apr|4)  month="April" ;;
    may|5)  month="May" ;;
    jun|6)  month="June" ;;
    jul|7)  month="July" ;;
    aug|8)  month="August" ;;
    sep|9)  month="September" ;;
    oct|10) month="October" ;;
    nov|11) month="November" ;;
    dec|12) month="December" ;;
    *)      month="$mon" ;;
  esac

  if [[ ${#yy} -eq 2 ]]; then
    local n=$((10#$yy))
    if (( n <= 69 )); then
      year=$((2000 + n))
    else
      year=$((1900 + n))
    fi
  else
    year="$yy"
  fi

  if [[ -n "$month" && -n "$year" ]]; then
    echo "${month}, ${year}"
  else
    echo ""
  fi
}

extract_release_date() {
  local file="$1"
  local fallback_raw="${2:-}"
  local line raw normalized


  line="$(grep -Ei 'Released[[:space:]]*:' "$file" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    echo "$line" | sed -E 's/.*Released[[:space:]]*:[[:space:]]*//I'
    return 0
  fi


  line="$(grep -Ei '^[[:space:]]*Date[[:space:]]*:' "$file" | head -n1 || true)"
  if [[ -n "$line" ]]; then
    raw="$(echo "$line" | sed -E 's/.*Date[[:space:]]*:[[:space:]]*//I' | awk '{print $1}')"
    normalized="$(normalize_ddmonyy_to_month_year "$raw")"
    if [[ -n "$normalized" ]]; then
      echo "$normalized"
      return 0
    fi
  fi

  if [[ -n "$fallback_raw" ]]; then
    normalized="$(normalize_ddmonyy_to_month_year "$fallback_raw")"
    if [[ -n "$normalized" ]]; then
      echo "$normalized"
      return 0
    fi
  fi

  echo ""
}

# Header TSV
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "zip_file" "root_folder" "patch_name" "major_version" "full_version" "product_type" "release_date"

tmp_files=()

cleanup() {
  for f in "${tmp_files[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

for zip in "$@"; do
  if [[ ! -f "$zip" ]]; then
    echo "Warning: file not found: $zip" >&2
    continue
  fi

  # Root folder = top-level directory of first entry
  local_first="$(zipinfo -1 "$zip" 2>/dev/null | head -n1 || true)"
  if [[ -n "$local_first" && "$local_first" == */* ]]; then
    root_dir="${local_first%%/*}"
  else
    root_dir="$local_first"
  fi

  readme_path="$(find_readme_in_zip "$zip" || true)"
  if [[ -z "$readme_path" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(basename "$zip")" "$root_dir" "" "" "" "" ""
    continue
  fi


  zip_date="$(zipinfo -l "$zip" "$readme_path" 2>/dev/null | \
              awk -v p="$readme_path" '$NF==p {print $(NF-2)}' | tail -n1 || true)"


  tmp="$(mktemp)"
  tmp_files+=("$tmp")
  unzip -p "$zip" "$readme_path" 2>/dev/null | tr -d '\r' > "$tmp"

  ptype="$(detect_product_type "$tmp")"
  pname="$(extract_patch_name "$tmp")"
  read -r full_ver major_ver <<<"$(extract_versions "$tmp" "$ptype")"
  rdate="$(extract_release_date "$tmp" "$zip_date")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(basename "$zip")" \
    "$root_dir" \
    "$pname" \
    "$major_ver" \
    "$full_ver" \
    "$ptype" \
    "$rdate"
done
