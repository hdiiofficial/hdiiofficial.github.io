cd /root/ip555-org-vps
cat << 'EOF' > scan_folder_candidates.js
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const SCAN_DIR = process.env.SCAN_DIR || '/root/ip555-org-vps/SCAN/SCAN';
const TARGET_DPS_ID = process.env.TARGET_DPS_ID || 'dps_13';
const APPLY = process.env.APPLY === '1';

if (!fs.existsSync(SCAN_DIR)) {
  console.error('FOLDER_TIDAK_DITEMUKAN:', SCAN_DIR);
  process.exit(1);
}

function normalizeNameFromFilename(filename) {
  const base = path.basename(filename, path.extname(filename));
  return base
    .replace(/\s*\(\s*1\s*\)\s*$/i, '')
    .replace(/\s*\(\s*2\s*\)\s*$/i, '')
    .replace(/\s*[-_]*(pas\s*foto|pasfoto|foto|ktp)\s*$/i, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toUpperCase();
}

function classifySlot(filename) {
  const base = path.basename(filename, path.extname(filename));
  if (/\(\s*1\s*\)\s*$/i.test(base) || /pas[\s_-]*foto/i.test(base)) return 'pas_foto';
  if (/\(\s*2\s*\)\s*$/i.test(base) || /\bktp\b/i.test(base)) return 'foto_ktp';
  return 'unknown';
}

function walkFiles(dir) {
  let out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('__MACOSX') || entry.name.startsWith('.')) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out = out.concat(walkFiles(full));
    else if (/\.(jpe?g|png|webp)$/i.test(entry.name)) out.push(full);
  }
  return out;
}

const files = walkFiles(SCAN_DIR);
const peopleMap = new Map();
const folderCounts = new Map();

for (const f of files) {
  const rel = path.relative(SCAN_DIR, f);
  const parts = rel.split(path.sep);
  const folderName = parts.length > 1 ? parts[0] : 'ROOT';
  const personName = normalizeNameFromFilename(f);
  if (!personName) continue;

  const slot = classifySlot(f);
  const key = `${folderName}::${personName}`;
  if (!peopleMap.has(key)) {
    peopleMap.set(key, {
      nama: personName,
      folder: folderName,
      pas_foto_src: null,
      foto_ktp_src: null,
      extra_files: []
    });
  }
  const p = peopleMap.get(key);
  if (slot === 'pas_foto' && !p.pas_foto_src) p.pas_foto_src = f;
  else if (slot === 'foto_ktp' && !p.foto_ktp_src) p.foto_ktp_src = f;
  else if (!p.pas_foto_src) p.pas_foto_src = f;
  else if (!p.foto_ktp_src) p.foto_ktp_src = f;
  else p.extra_files.push(f);

  folderCounts.set(folderName, (folderCounts.get(folderName) || 0) + 1);
}

const allPeople = Array.from(peopleMap.values());
const totalPeople = allPeople.length;
const completePairs = allPeople.filter((p) => p.pas_foto_src && p.foto_ktp_src).length;
const incomplete = allPeople.filter((p) => !p.pas_foto_src || !p.foto_ktp_src);

console.log('SCAN_DIR:', SCAN_DIR);
console.log('TARGET_DPS:', TARGET_DPS_ID, '(DPS Kranggan)');
console.log('TOTAL_FILE_GAMBAR:', files.length);
console.log('TOTAL_ORANG_TERDETEKSI:', totalPeople);
console.log('PASANGAN_LENGKAP_1_PASFOTO_1_KTP:', completePairs);
console.log('BELUM_LENGKAP_PASANGAN:', incomplete.length);
if (incomplete.length > 0) {
  console.log('CONTOH_BELUM_LENGKAP:', incomplete.slice(0, 12).map((x) => ({ nama: x.nama, folder: x.folder, hasFoto: !!x.pas_foto_src, hasKtp: !!x.foto_ktp_src })));
}
console.log('RINGKASAN_PER_FOLDER:', Object.fromEntries(folderCounts));

if (!APPLY) {
  console.log('MODE_SCAN_SELESAI. Untuk memasukkan SEMUA ke ' + TARGET_DPS_ID + ' (DPS Kranggan), jalankan: APPLY=1 node scan_folder_candidates.js');
  process.exit(0);
}

const db = new Database('/root/ip555-org-vps/data/ip555.db');
const dataDirPublic = '/root/ip555-org-vps/public/datadiri';
fs.mkdirSync(dataDirPublic, { recursive: true });

const candCols = db.prepare('PRAGMA table_info(candidates)').all().map((c) => c.name);
const hasCreatedAt = candCols.includes('created_at');
const hasUpdatedAt = candCols.includes('updated_at');

const insertTx = db.transaction(() => {
  allPeople.forEach((p, idx) => {
    const stamp = Date.now() + idx;
    const rand = Math.random().toString(36).slice(2, 6);

    let pasFotoUrl = '';
    if (p.pas_foto_src) {
      const ext = path.extname(p.pas_foto_src).toLowerCase() || '.jpg';
      const fname = `scan_pasfoto_${stamp}_${rand}${ext}`;
      fs.copyFileSync(p.pas_foto_src, path.join(dataDirPublic, fname));
      pasFotoUrl = `/datadiri/${fname}`;
    }

    let fotoKtpUrl = '';
    if (p.foto_ktp_src) {
      const ext = path.extname(p.foto_ktp_src).toLowerCase() || '.jpg';
      const fname = `scan_ktp_${stamp}_${rand}${ext}`;
      fs.copyFileSync(p.foto_ktp_src, path.join(dataDirPublic, fname));
      fotoKtpUrl = `/datadiri/${fname}`;
    }

    const id = `calon_scan_${stamp}_${rand}`;
    const nowIso = new Date().toISOString();

    const rowObj = {
      id,
      dps_id: TARGET_DPS_ID,
      nama: p.nama,
      nik: '',
      no_hp: '',
      alamat: '',
      usaha: '',
      catatan: '',
      pas_foto: pasFotoUrl,
      foto_ktp: fotoKtpUrl
    };
    if (hasCreatedAt) rowObj.created_at = nowIso;
    if (hasUpdatedAt) rowObj.updated_at = nowIso;

    const validKeys = Object.keys(rowObj).filter((k) => candCols.includes(k));
    const placeholders = validKeys.map(() => '?').join(', ');
    const sql = `INSERT INTO candidates (${validKeys.join(', ')}) VALUES (${placeholders})`;
    db.prepare(sql).run(...validKeys.map((k) => rowObj[k]));
  });
});

insertTx();
console.log('IMPORT_ALL_TO_DPS_KRANGGAN_OK', { totalInserted: totalPeople, dps_id: TARGET_DPS_ID });
EOF

APPLY=0 node scan_folder_candidates.js
