import { useEffect, useState } from 'react';
import { Download, Loader2 } from 'lucide-react';
import { useTranslation } from 'react-i18next';
import QRCode from 'qrcode';
import Modal from '../ui/Modal';
import { Button } from '../ui/Button';
import { buildMarketQrPdf, storefrontUrl } from '../lib/qrPdf';
import { machineName } from '../lib/machines';

// Previews a machine's QR (links to the storefront on this same Vercel
// deployment) with a button to download it as a printable PDF.
export default function QrModal({ market, onClose }) {
  const { t } = useTranslation();
  const [qrSrc, setQrSrc] = useState(null);
  const [pdfUrl, setPdfUrl] = useState(null);
  const [pdfErr, setPdfErr] = useState(null);
  const url = storefrontUrl(market);
  useEffect(() => {
    let alive = true;
    let createdUrl = null;
    (async () => {
      const qr = await QRCode.toDataURL(url, { width: 600, margin: 1, errorCorrectionLevel: 'M' });
      if (!alive) return;
      setQrSrc(qr);
      // Pre-build the PDF blob now (not on click) so the download is a plain
      // anchor click — avoids browsers blocking a download triggered after await.
      const blob = await buildMarketQrPdf(market, qr, t);
      if (!alive) return;
      createdUrl = URL.createObjectURL(blob);
      setPdfUrl(createdUrl);
    })().catch((e) => { console.error('[QrModal] build failed', e); if (alive) setPdfErr(String((e && e.message) || e)); });
    return () => { alive = false; if (createdUrl) URL.revokeObjectURL(createdUrl); };
  }, [url, market]);

  return (
    <Modal
      title={t('qr_machine')}
      subtitle={`${machineName(market, t)} · ${t('apparatus_no')}${market.id}`}
      onClose={onClose}
      size="sm"
      mobile="sheet"
      footer={pdfUrl ? (
        <a
          href={pdfUrl}
          download={`qr-apparat-${market.id}.pdf`}
          className="w-full inline-flex items-center justify-center gap-2 min-h-11 rounded-[10px] bg-brand text-white font-bold hover:bg-brand-dark focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-blue-300"
        >
          <Download size={18} /> {t('download_qr_pdf')}
        </a>
      ) : pdfErr ? (
        <div className="w-full text-center bg-rose-50 border border-rose-200 text-rose-800 py-3 px-3 rounded-[8px] text-sm font-semibold break-words">
          {t('pdf_error')}: {pdfErr}
        </div>
      ) : (
        <Button variant="secondary" block loading disabled>{t('preparing')}</Button>
      )}
    >
      <div className="text-center">
        <div className="bg-white border border-slate-200 rounded-[12px] p-4 inline-block">
          {qrSrc ? (
            <img src={qrSrc} alt="QR" className="w-56 h-56" />
          ) : (
            <div className="w-56 h-56 flex items-center justify-center"><Loader2 className="animate-spin text-slate-400" size={32} /></div>
          )}
        </div>
        <a href={url} target="_blank" rel="noreferrer" className="mt-3 block text-[13px] text-slate-600 hover:text-brand-dark break-all">{url}</a>
      </div>
    </Modal>
  );
}
