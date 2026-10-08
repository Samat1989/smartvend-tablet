import QRCode from 'qrcode';

// Base URL the QR points at — the customer storefront. Set VITE_STOREFRONT_URL
// to the deployed storefront origin; falls back to the current origin.
export const STOREFRONT_BASE = import.meta.env.VITE_STOREFRONT_URL || (typeof window !== 'undefined' ? window.location.origin : '');

export const storefrontUrl = (market) => `${STOREFRONT_BASE}/micromarket?t=${market.qr_token}`;

// Build a minimal one-page A4 PDF Blob embedding `canvas` as a JPEG image.
// Dependency-free (no jsPDF) — bundling jsPDF produced an unusable constructor
// in the Vercel/Node production build, so we emit the PDF bytes ourselves.
function buildPdfBlobFromCanvas(canvas) {
  const jpegB64 = canvas.toDataURL('image/jpeg', 0.92).split(',')[1];
  const bin = atob(jpegB64);
  const jpeg = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) jpeg[i] = bin.charCodeAt(i);

  const W = canvas.width, H = canvas.height;
  const CM = 28.3465; // points per cm
  const pageW = 7 * CM;          // 7cm wide
  const pageH = pageW * (H / W); // height follows the canvas — no empty bottom
  const drawW = pageW;
  const drawH = pageH;
  const x = 0;
  const y = 0;
  const content = `q\n${drawW.toFixed(2)} 0 0 ${drawH.toFixed(2)} ${x.toFixed(2)} ${y.toFixed(2)} cm\n/Im0 Do\nQ\n`;

  const enc = new TextEncoder();
  const parts = [];
  const offsets = [];
  let length = 0;
  const push = (u8) => { parts.push(u8); length += u8.length; };
  const pushStr = (s) => push(enc.encode(s));
  const addObj = (fn) => { offsets.push(length); fn(); };

  pushStr('%PDF-1.3\n');
  addObj(() => pushStr('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'));
  addObj(() => pushStr('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'));
  addObj(() => pushStr(`3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageW} ${pageH}] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n`));
  addObj(() => {
    pushStr(`4 0 obj\n<< /Type /XObject /Subtype /Image /Width ${W} /Height ${H} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`);
    push(jpeg);
    pushStr('\nendstream\nendobj\n');
  });
  const contentBytes = enc.encode(content);
  addObj(() => {
    pushStr(`5 0 obj\n<< /Length ${contentBytes.length} >>\nstream\n`);
    push(contentBytes);
    pushStr('\nendstream\nendobj\n');
  });

  const xrefStart = length;
  let xref = 'xref\n0 6\n0000000000 65535 f \n';
  for (const off of offsets) xref += String(off).padStart(10, '0') + ' 00000 n \n';
  pushStr(xref);
  pushStr(`trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xrefStart}\n%%EOF`);

  const out = new Uint8Array(length);
  let pos = 0;
  for (const p of parts) { out.set(p, pos); pos += p.length; }
  return new Blob([out], { type: 'application/pdf' });
}

// Build + download a printable PDF with the machine's QR (encodes
// <storefront>/?marketId=<id>). Rendered via canvas so Cyrillic text works
// (jsPDF's built-in fonts don't support it).
export async function buildMarketQrPdf(market, qrDataUrl, t) {
  const url = storefrontUrl(market);
  if (!qrDataUrl) qrDataUrl = await QRCode.toDataURL(url, { width: 900, margin: 1, errorCorrectionLevel: 'M' });

  // 7cm wide; the height is trimmed to the content (no empty bottom). QR stays
  // square so it scans. 100 px per cm.
  const canvas = document.createElement('canvas');
  canvas.width = 700;
  canvas.height = 920;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.textAlign = 'center';
  const cx = canvas.width / 2;

  ctx.fillStyle = '#111827';
  ctx.font = 'bold 42px sans-serif';
  ctx.fillText(`${t('apparatus_no')}${market.id}`, cx, 72);

  const img = new window.Image();
  await new Promise((resolve, reject) => {
    img.onload = resolve;
    img.onerror = reject;
    img.src = qrDataUrl;
  });
  const qrSize = 620; // ~6.2 cm square
  ctx.drawImage(img, (canvas.width - qrSize) / 2, 110, qrSize, qrSize);

  ctx.fillStyle = '#111827';
  ctx.font = 'bold 42px sans-serif';
  ctx.fillText(t('qr_scan_to'), cx, 800);
  ctx.fillText(t('qr_to_buy'), cx, 850);
  ctx.fillStyle = '#9ca3af';
  ctx.font = '20px sans-serif';
  ctx.fillText(url, cx, 895);

  return buildPdfBlobFromCanvas(canvas);
}
