#!/bin/zsh
# Downloads the CC0 recordings listed below from Freesound and cuts them into Resources/Packs and Resources/Effects.
# Only needed to change a cut: the results are already in the repo. Needs ffmpeg.
# cut <freesound id> <start> <length> <fade-out> <output> [pitch, 1 = as recorded]
set -euo pipefail
cd "${0:A:h}/.."
CACHE=${SOUND_CACHE:-.build/freesound}; mkdir -p $CACHE
fetch() {  # id user
  [[ -s $CACHE/$1.mp3 ]] && return
  local page=$(curl -sfL -A Mozilla/5.0 "https://freesound.org/people/$2/sounds/$1/")
  [[ $page == *creativecommons.org/publicdomain/zero/1.0* ]] || { echo "$1 is not CC0"; exit 1 }
  local url=$(print -r -- "$page" | grep -oE "https://cdn.freesound.org/previews/[0-9]+/$1_[0-9]+-lq.mp3" | head -1)
  curl -sfL -A Mozilla/5.0 "${url/-lq./-hq.}" -o $CACHE/$1.mp3
}
cut() {
  mkdir -p "${5:h}"
  ffmpeg -v error -y -i $CACHE/$1.mp3 -af "atrim=$2:$(($2 + $3)),asetpts=PTS-STARTPTS,aresample=44100,asetrate=$((44100 * ${6:-1})),aresample=44100,volume=-4dB,afade=t=out:st=$((($3 - $4) / ${6:-1})):d=$(($4 / ${6:-1}))" \
    -ac 1 -c:a pcm_s16le -map_metadata -1 -fflags +bitexact "$5"
}
while read id user; do fetch $id $user; done <<L
607215 jonopodmore
863784 sazanami12
668647 tec_studio
329098 Macif
214675 Macif
749203 itinerantmonk108
785585 Detective_Lemons
550340 Nox_Sound
403507 LamaMakesMusic
273870 beskhu
573152 fleurescence
573153 fleurescence
803158 kerozenne
277291 TinTinOko
159375 Greenhourglass
412017 skymary
209578 Zott820
558858 DigPro120
L
rm -rf Resources/Packs Resources/Effects
P=Resources/Packs E=Resources/Effects

# Wooden fish
i=1; for r in 1 0.97 1.03; do cut 607215 0 0.40 0.15 $P/muyu/press$((i++)).wav $r; done
cut 607215 0 0.45 0.15 $P/muyu/space.wav 0.80
cut 863784 5.00 0.40 0.15 $P/muyu/backspace.wav
cut 668647 0 3.5 1.8 $P/muyu/enter.wav

# Mahjong (the key sounds are domino pieces, which knock like mahjong tiles)
i=1; for t in 0.765 1.28 1.77 2.255 2.735 6.425 6.905 7.395; do cut 329098 $((t - 0.02)) 0.25 0.08 $P/mahjong/press$((i++)).wav; done
cut 329098 11.215 0.30 0.10 $P/mahjong/space.wav 0.8
cut 329098 14.76 0.25 0.08 $P/mahjong/backspace.wav 1.15
cut 785585 0.54 1.75 0.35 $P/mahjong/enter.wav

# Bubble wrap
i=1; for t in 0.15 0.67 1.895 2.38 3.06 3.80 4.765 6.075; do cut 214675 $((t - 0.02)) 0.20 0.06 $P/bubble/press$((i++)).wav; done
cut 214675 5.245 0.30 0.08 $P/bubble/space.wav 0.85
cut 214675 10.075 0.25 0.06 $P/bubble/backspace.wav 1.1
cut 749203 2.36 0.72 0.12 $P/bubble/enter.wav

# Typewriter
i=1; for t in 2.383 3.474 4.572 5.67; do   # the hammer strike, just after the key starts to move
  cut 550340 $t 0.14 0.04 $P/typewriter/press$i.wav; cut 550340 $((t + 0.14)) 0.25 0.08 $P/typewriter/release$((i++)).wav
done
cut 550340 4.572 0.14 0.04 $P/typewriter/space.wav 0.82
cut 550340 6.73 1.55 0.25 $P/typewriter/enter.wav

# Rubber duck
i=1; for t in 1.34 2.665 3.91; do cut 403507 $((t - 0.02)) 0.42 0.12 $P/duck/press$((i++)).wav; done
cut 403507 0.34 0.55 0.15 $P/duck/space.wav 0.85
cut 403507 9.68 0.45 0.12 $P/duck/backspace.wav
cut 558858 0.18 1.45 0.15 $P/duck/enter.wav

# Water drop and mouth pop: one or two takes, so the rest are pitched copies
i=1; for r in 0.85 0.93 1 1.08 1.17; do cut 273870 0 0.35 0.12 $P/water/press$((i++)).wav $r; done
cut 273870 0 0.36 0.12 $P/water/space.wav 0.62
cut 273870 0 0.36 0.12 $P/water/enter.wav 0.48
i=1; for r in 0.92 1 1.1; do cut 573152 0 0.25 0.10 $P/pop/press$((i++)).wav $r; cut 573153 0 0.18 0.08 $P/pop/press$((i++)).wav $r; done
cut 573152 0 0.30 0.10 $P/pop/space.wav 0.65
cut 573153 0 0.18 0.08 $P/pop/backspace.wav 1.4
cut 573152 0 0.30 0.10 $P/pop/enter.wav 0.5

# One-off effects for special keys
cut 803158 3.72 3.4 1.8 $E/gong.wav
cut 668647 0 3.5 1.8 $E/templebell.wav
cut 277291 0 1.2 0.4 $E/boing.wav
cut 159375 0 0.95 0.15 $E/arcade.wav
cut 412017 0.30 0.95 0.2 $E/meow.wav
cut 209578 0.04 1.6 0.4 $E/cash.wav
cut 558858 0.18 0.22 0.05 $E/quack.wav
cut 403507 0.34 0.55 0.15 $E/squeak.wav
cut 785585 0.54 1.75 0.35 $E/tiles.wav
cut 749203 2.36 0.72 0.12 $E/bubbles.wav
cut 550340 6.73 1.55 0.25 $E/carriage.wav
cut 607215 0 0.40 0.15 $E/muyu.wav
