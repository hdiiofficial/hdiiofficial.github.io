cd /root/ip555-org-vps
cat << 'EOF' > auto_redbg_scan_nodejs.js
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const Database = require('better-sqlite3');

const DATA_DIR = '/root/ip555-org-vps/public/datadiri';
const DB_PATH = '/root/ip555-org-vps/data/ip555.db';

if (!fs.existsSync(DATA_DIR)) {
  console.error('FOLDER_DATADIRI_TIDAK_DITEMUKAN:', DATA_DIR);
  process.exit(1);
}

// Cek ketersediaan sharp di Node.js atau ffmpeg di sistem
let hasSharp = false;
try {
  require.resolve('sharp');
  hasSharp = true;
} catch (_) {}

let hasFfmpeg = false;
try {
  execSync('command -v ffmpeg', { stdio: 'ignore' });
  hasFfmpeg = true;
} catch (_) {}

let hasConvert = false;
try {
  execSync('command -v convert', { stdio: 'ignore' });
  hasConvert = true;
} catch (_) {}

console.log('NODE_TOOLS:', { hasSharp, hasFfmpeg, hasConvert });

const files = fs.readdirSync(DATA_DIR).filter((f) => /^scan_pasfoto_/i.test(f) && !/_redbg_/i.test(f));
if (files.length === 0) {
  console.log('TIDAK_ADA_FILE_SCAN_PASFOTO_UNTUK_DIPROSES');
  process.exit(0);
}

const db = new Database(DB_PATH);
const updateStmt = db.prepare('UPDATE candidates SET pas_foto = ? WHERE pas_foto = ?');

async function processWithSharp() {
  const sharp = require('sharp');
  let ok = 0;

  for (const fname of files) {
    const srcPath = path.join(DATA_DIR, fname);
    const parsed = path.parse(fname);
    const outName = `${parsed.name}_redbg_${Date.now()}.jpg`;
    const outPath = path.join(DATA_DIR, outName);

    const { data, info } = await sharp(srcPath)
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });

    const buf = Buffer.from(data);
    for (let i = 0; i < buf.length; i += 4) {
      const r = buf[i];
      const g = buf[i + 1];
      const b = buf[i + 2];
      const a = buf[i + 3];

      const blueDiff = b - r;
      const isBlueBg = blueDiff > 18 && b > 75 && a > 10;
      const isSkin = r > 120 && g > 75 && r > b + 20;
      const isDark = r < 65 && g < 65 && b < 65;

      if (isBlueBg && !isSkin && !isDark) {
        const strength = Math.min(1, Math.max(0, (blueDiff - 18) / 45));
        const luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
        const shade = Math.min(1.25, Math.max(0.65, 0.75 + 0.45 * luma));

        const targetR = Math.min(255, Math.round(215 * shade));
        const targetG = Math.min(255, Math.round(38 * shade));
        const targetB = Math.min(255, Math.round(38 * shade));

        buf[i] = Math.round(r * (1 - strength) + targetR * strength);
        buf[i + 1] = Math.round(g * (1 - strength) + targetG * strength);
        buf[i + 2] = Math.round(b * (1 - strength) + targetB * strength);
      }
    }

    await sharp(buf, {
      raw: { width: info.width, height: info.height, channels: 4 }
    })
      .flatten({ background: { r: 215, g: 38, b: 38 } })
      .jpeg({ quality: 92 })
      .toFile(outPath);

    const oldUrl = `/datadiri/${fname}`;
    const newUrl = `/datadiri/${outName}`;
    updateStmt.run(newUrl, oldUrl);
    ok++;
  }

  console.log('AUTO_REDBG_SHARP_OK', { total: files.length, converted: ok });
}

function processWithFfmpeg() {
  let ok = 0;
  for (const fname of files) {
    const srcPath = path.join(DATA_DIR, fname);
    const parsed = path.parse(fname);
    const outName = `${parsed.name}_redbg_${Date.now()}.jpg`;
    const outPath = path.join(DATA_DIR, outName);

    // Ganti piksel biru latar belakang menggunakan filter geq di FFmpeg
    const geqExpr = "if(gt(b-r,18)*gt(b,75)*not(gt(r,120)*gt(g,75)*gt(r-b,20)),210,r):if(gt(b-r,18)*gt(b,75)*not(gt(r,120)*gt(g,75)*gt(r-b,20)),35,g):if(gt(b-r,18)*gt(b,75)*not(gt(r,120)*gt(g,75)*gt(r-b,20)),35,b)";
    execSync(`ffmpeg -y -i "${srcPath}" -vf "geq='${geqExpr}'" -q:v 2 "${outPath}"`, { stdio: 'ignore' });

    const oldUrl = `/datadiri/${fname}`;
    const newUrl = `/datadiri/${outName}`;
    updateStmt.run(newUrl, oldUrl);
    ok++;
  }
  console.log('AUTO_REDBG_FFMPEG_OK', { total: files.length, converted: ok });
}

(async () => {
  try {
    if (hasSharp) {
      await processWithSharp();
    } else if (hasFfmpeg) {
      processWithFfmpeg();
    } else {
      console.log('SHARP_DAN_FFMPEG_BELUM_ADA. Install sharp dengan: npm install sharp');
    }
  } catch (err) {
    console.error('AUTO_REDBG_ERR:', err.message);
    process.exit(1);
  }
})();
EOF

node auto_redbg_scan_nodejs.js && rm -f auto_redbg_scan_nodejs.js
