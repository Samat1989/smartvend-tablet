// Longest side handed to the cropper. Canvas stops rendering somewhere around
// 16.7 Mpx on Safari/iOS and phones shoot well past that, so anything bigger
// is downscaled first. The crop is re-encoded to 600px anyway.
export const MAX_SOURCE_PX = 2000;
export const MAX_SOURCE_BYTES = 40 * 1024 * 1024;

// What the file dialog offers. `image/*` alone let through HEIC and TIFF,
// which the browser then refused to decode; the explicit list puts the
// formats that work first and keeps `image/*` as the fallback for Android's
// file picker, which narrows badly on a strict list.
export const PHOTO_ACCEPT =
  'image/jpeg,image/png,image/webp,image/avif,image/gif,image/heic,image/heif,image/*';

// The shared photo bank, published by scripts/import_photo_library.py. Names
// are the md5 of the file, so these URLs are immutable and cache for a year:
//   <base>/<md5>.webp      600px, what a shopper sees
//   <base>/t/<md5>.webp     200px, the grid below
//   <base>/index.json       [{ n: name, f: md5 }, ...]
export const LIBRARY_BASE =
  `${import.meta.env.VITE_SUPABASE_URL}/storage/v1/object/public/product-images/library`;

// How many tiles are added per page. The whole bank is ~3000 entries and
// rendering them at once would mean ~3000 image requests; the index itself is
// only names, so searching stays instant regardless.
export const LIBRARY_PAGE = 60;

/**
 * Turn a picked file into something <Cropper> can actually display — or
 * throw a message worth showing to a human.
 *
 * Everything here exists because the previous version had no failure path
 * at all: a file the browser cannot decode used to leave the cropper open
 * full-screen and black until the operator pressed Cancel, with no hint of
 * what went wrong. An iPhone photo hit that every time.
 */
export async function prepareForCrop(file, t) {
  if (file.size > MAX_SOURCE_BYTES) throw new Error(t('photo_too_large'));

  let blob = file;

  // HEIC/HEIF is what an iPhone hands over by default and what nothing but
  // Safari decodes. heic2any carries a libheif build (~1 MB), so it is
  // imported only once one actually shows up.
  if (/hei[cf]/i.test(file.type) || /\.hei[cf]$/i.test(file.name)) {
    try {
      const { default: heic2any } = await import('heic2any');
      const out = await heic2any({ blob: file, toType: 'image/png' });
      blob = Array.isArray(out) ? out[0] : out;
    } catch (err) {
      console.error('HEIC decode failed:', err);
      throw new Error(t('photo_heic_failed'), { cause: err });
    }
  }

  // Decode once, up front. TIFF, a truncated download, a .jpg that is not
  // one — all fail here, and the modal never opens.
  let bmp;
  try {
    bmp = await createImageBitmap(blob, { imageOrientation: 'from-image' });
  } catch {
    throw new Error(t('photo_format_unsupported'));
  }

  try {
    // Small enough already: hand the original over untouched. The <img> the
    // cropper renders applies EXIF orientation on its own, same as the
    // bitmap above, so a portrait phone shot stays upright either way.
    if (Math.max(bmp.width, bmp.height) <= MAX_SOURCE_PX) {
      return URL.createObjectURL(blob);
    }

    // Canvas tops out near 16.7 Mpx on Safari/iOS and a modern phone shoots
    // well past that, so a 50 Mpx photo would simply never render.
    const scale = MAX_SOURCE_PX / Math.max(bmp.width, bmp.height);
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(bmp.width * scale);
    canvas.height = Math.round(bmp.height * scale);
    canvas.getContext('2d').drawImage(bmp, 0, 0, canvas.width, canvas.height);
    const small = await new Promise((resolve, reject) => canvas.toBlob(
      b => (b ? resolve(b) : reject(new Error(t('photo_format_unsupported')))),
      'image/webp', 0.92));
    return URL.createObjectURL(small);
  } finally {
    bmp.close();
  }
}

// Crop to a 600×600 WebP on white.
export function getCroppedImg(imageSrc, pixelCrop, t) {
  return new Promise((resolve, reject) => {
    const img = new window.Image();
    img.src = imageSrc;
    img.onload = () => {
      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d');

      const targetSize = 600;
      canvas.width = targetSize;
      canvas.height = targetSize;

      ctx.fillStyle = 'white';
      ctx.fillRect(0, 0, targetSize, targetSize);

      ctx.drawImage(
        img,
        pixelCrop.x,
        pixelCrop.y,
        pixelCrop.width,
        pixelCrop.height,
        0,
        0,
        targetSize,
        targetSize
      );

      canvas.toBlob((blob) => {
        if (!blob) return reject(new Error('Canvas empty'));
        resolve(blob);
      }, 'image/webp', 0.85);
    };
    // Was `img.onerror = reject`, which rejects with an Event — and the
    // catch below renders it as {"isTrusted":true} in the toast.
    img.onerror = () => reject(new Error(t('photo_format_unsupported')));
  });
}
