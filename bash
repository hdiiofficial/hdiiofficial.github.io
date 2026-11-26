cd /root/ip555-org-vps
cat << 'EOF' > clean_scan_candidates.js
const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const APPLY = process.env.APPLY === '1';
const MODE = process.env.MODE || 'scan_only'; // 'scan_only' | 'all_candidates'

const db = new Database('/root/ip555-org-vps/data/ip555.db');
const dataDirPublic = '/root/ip555-org-vps/public/datadiri';

const rows = MODE === 'all_candidates'
  ? db.prepare('SELECT id, nama, dps_id, pas_foto, foto_ktp FROM candidates').all()
  : db.prepare("SELECT id, nama, dps_id, pas_foto, foto_ktp FROM candidates WHERE id LIKE 'calon_scan_%' OR pas_foto LIKE '/datadiri/scan_%' OR foto_ktp LIKE '/datadiri/scan_%'").all();

const scanFiles = fs.existsSync(dataDirPublic)
  ? fs.readdirSync(dataDirPublic).filter((f) => f.startsWith('scan_pasfoto_') || f.startsWith('scan_ktp_'))
  : [];

console.log('MODE_HAPUS:', MODE);
console.log('JUMLAH_BARIS_CALON_TARGET:', rows.length);
console.log('JUMLAH_FILE_SCAN_DI_DATADIRI:', scanFiles.length);

if (!APPLY) {
  console.log('MODE_PREVIEW_SAJA. Belum ada yang dihapus.');
  console.log('Untuk hapus khusus hasil SCAN saja: APPLY=1 MODE=scan_only node clean_scan_candidates.js');
  console.log('Untuk hapus SEMUA isi tabel candidates: APPLY=1 MODE=all_candidates node clean_scan_candidates.js');
  process.exit(0);
}

const delTx = db.transaction(() => {
  if (MODE === 'all_candidates') {
    db.prepare('DELETE FROM candidates').run();
  } else {
    db.prepare("DELETE FROM candidates WHERE id LIKE 'calon_scan_%' OR pas_foto LIKE '/datadiri/scan_%' OR foto_ktp LIKE '/datadiri/scan_%'").run();
  }
});
delTx();

let removedFiles = 0;
if (MODE === 'scan_only') {
  for (const f of scanFiles) {
    const full = path.join(dataDirPublic, f);
    if (fs.existsSync(full)) {
      fs.unlinkSync(full);
      removedFiles++;
    }
  }
}

console.log('HAPUS_DATA_CALON_SELESAI', {
  mode: MODE,
  deletedRows: rows.length,
  deletedScanFiles: removedFiles
});
EOF

APPLY=0 MODE=scan_only node clean_scan_candidates.js
