cd /root/ip555-org-vps
cat << 'EOF' > scan_folder_candidates.js
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const SCAN_DIR = process.env.SCAN_DIR || '/root/ip555-org-vps/SCAN/SCAN';
const TARGET_DPS_ID = process.env.TARGET_DPS_ID || 'dps_13';
const APPLY = process.env.APPLY === '1';
const CLEAN_PREV = process.env.CLEAN_PREV === '1';

if (!fs.existsSync(SCAN_DIR)) {
  console.error('FOLDER_TIDAK_DITEMUKAN:', SCAN_DIR);
  process.exit(1);
}

function parseCandidateFile(filename) {
  const ext = path.extname(filename);
  const base = path.basename(filename, ext);

  // Cocokkan pola: "<NAMA> (1)" atau "<NAMA>(1)" untuk pas foto, dan "(2)" untuk KTP
  const m1 = base.match(/^(.*?)\s*\(\s*1\s*\)\s*$/);
  if (m1) {
    const nama = m1[1].replace(/\s+/g, ' ').trim().toUpperCase();
    return { nama, slot: 'pas_foto', matchedPattern: true };
  }

  const m2 = base.match(/^(.*?)\s*\(\s*2\s*\)\s*$/);
  if (m2) {
    const nama = m2[1].replace(/\s+/g, ' ').trim().toUpperCase();
    return { nama, slot: 'foto_ktp', matchedPattern: true };
  }

  const cleanNama = base
    .replace(/\s*\(\s*\d+\s*\)\s*$/, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toUpperCase();

  return { nama: cleanNama, slot: 'other', matchedPattern: false };
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
const groups = new Map();
const extraOrUnmatched = [];

for (const f of files) {
  const rel = path.relative(SCAN_DIR, f);
  const parts = rel.split(path.sep);
  const folderName = parts.length > 1 ? parts[0] : 'ROOT';
  const parsed = parseCandidateFile(f);
  if (!parsed.nama) continue;

  const key = `${folderName}::${parsed.nama}`;
  if (!groups.has(key)) {
    groups.set(key, {
      nama: parsed.nama,
      folder: folderName,
      pas_foto_files: [],
      foto_ktp_files: [],
      other_files: []
    });
  }
  const g = groups.get(key);
  if (parsed.slot === 'pas_foto') g.pas_foto_files.push(f);
  else if (parsed.slot === 'foto_ktp') g.foto_ktp_files.push(f);
  else g.other_files.push(f);
}

const validPairs = [];
const incompletePairs = [];

for (const g of groups.values()) {
  const hasFoto = g.pas_foto_files.length > 0;
  const hasKtp = g.foto_ktp_files.length > 0;

  if (g.pas_foto_files.length > 1 || g.foto_ktp_files.length > 1 || g.other_files.length > 0) {
    extraOrUnmatched.push({
      nama: g.nama,
      folder: g.folder,
      foto1Count: g.pas_foto_files.length,
      ktp2Count: g.foto_ktp_files.length,
      extraCount: g.other_files.length + Math.max(0, g.pas_foto_files.length - 1) + Math.max(0, g.foto_ktp_files.length - 1)
    });
  }

  if (hasFoto && hasKtp) {
    validPairs.push({
      nama: g.nama,
      folder: g.folder,
      pas_foto_src: g.pas_foto_files[0],
      foto_ktp_src: g.foto_ktp_files[0]
    });
  } else {
    incompletePairs.push({
      nama: g.nama,
      folder: g.folder,
      hasFoto1: hasFoto,
      hasKtp2: hasKtp,
      otherCount: g.other_files.length
    });
  }
}

console.log('SCAN_DIR:', SCAN_DIR);
console.log('TARGET_DPS:', TARGET_DPS_ID, '(DPS Kranggan)');
console.log('TOTAL_FILE_GAMBAR:', files.length);
console.log('TOTAL_ORANG_VALID_ADA_(1)_DAN_(2):', validPairs.length);
console.log('TIDAK_LENGKAP_(1)_ATAU_(2):', incompletePairs.length);
if (incompletePairs.length > 0) {
  console.log('CONTOH_TIDAK_LENGKAP:', incompletePairs.slice(0, 15));
}
console.log('NAMA_DENGAN_FILE_LEBIH_DARI_PASANGAN_(1)+(2):', extraOrUnmatched.length);
if (extraOrUnmatched.length > 0) {
  console.log('CONTOH_FILE_LEBIH_DARI_PASANGAN:', extraOrUnmatched.slice(0, 15));
}

if (!APPLY) {
  console.log('MODE_SCAN_SELESAI. Jika jumlah orang valid sudah sesuai, bersihkan data scan lama & import pasangan (1)+(2) ke dps_13 dengan:');
  console.log('CLEAN_PREV=1 APPLY=1 node scan_folder_candidates.js');
  process.exit(0);
}

const db = new Database('/root/ip555-org-vps/data/ip555.db');
const dataDirPublic = '/root/ip555-org-vps/public/datadiri';
fs.mkdirSync(dataDirPublic, { recursive: true });

if (CLEAN_PREV) {
  const oldFiles = fs.existsSync(dataDirPublic)
    ? fs.readdirSync(dataDirPublic).filter((fn) => fn.startsWith('scan_pasfoto_') || fn.startsWith('scan_ktp_'))
    : [];
  db.prepare("DELETE FROM candidates WHERE id LIKE 'calon_scan_%' OR pas_foto LIKE '/datadiri/scan_%' OR foto_ktp LIKE '/datadiri/scan_%'").run();
  for (const fn of oldFiles) {
    try { fs.unlinkSync(path.join(dataDirPublic, fn)); } catch (_) {}
  }
  console.log('OLD_SCAN_CLEANED:', oldFiles.length, 'files');
}

const candCols = db.prepare('PRAGMA table_info(candidates)').all().map((c) => c.name);
const hasCreatedAt = candCols.includes('created_at');
const hasUpdatedAt = candCols.includes('updated_at');

const insertTx = db.transaction(() => {
  validPairs.forEach((p, idx) => {
    const stamp = Date.now() + idx;
    const rand = Math.random().toString(36).slice(2, 6);

    const ext1 = path.extname(p.pas_foto_src).toLowerCase() || '.jpg';
    const fname1 = `scan_pasfoto_${stamp}_${rand}${ext1}`;
    fs.copyFileSync(p.pas_foto_src, path.join(dataDirPublic, fname1));

    const ext2 = path.extname(p.foto_ktp_src).toLowerCase() || '.jpg';
    const fname2 = `scan_ktp_${stamp}_${rand}${ext2}`;
    fs.copyFileSync(p.foto_ktp_src, path.join(dataDirPublic, fname2));

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
      pas_foto: `/datadiri/${fname1}`,
      foto_ktp: `/datadiri/${fname2}`
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
console.log('IMPORT_VALID_PAIRS_TO_KRANGGAN_OK', {
  inserted: validPairs.length,
  skippedIncomplete: incompletePairs.length,
  dps_id: TARGET_DPS_ID
});
EOF

APPLY=0 node scan_folder_candidates.js
