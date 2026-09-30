import {AppError} from './api.js';

export async function prepareAvatar(file) {
  if (!file || !['image/png','image/jpeg','image/webp'].includes(file.type)) throw new AppError('AVATAR_INVALID');
  if (file.size>8*1024*1024) throw new AppError('AVATAR_TOO_LARGE');
  const url=URL.createObjectURL(file);
  try {
    const image=new Image(); image.decoding='async'; image.src=url;
    try { await image.decode(); } catch { throw new AppError('AVATAR_INVALID'); }
    if (!image.naturalWidth || !image.naturalHeight || image.naturalWidth*image.naturalHeight>40000000) throw new AppError('AVATAR_TOO_LARGE');
    const canvas=document.createElement('canvas'); canvas.width=256; canvas.height=256;
    const ctx=canvas.getContext('2d');
    if (!ctx) throw new AppError('AVATAR_INVALID');
    const side=Math.min(image.naturalWidth,image.naturalHeight);
    ctx.drawImage(image,(image.naturalWidth-side)/2,(image.naturalHeight-side)/2,side,side,0,0,256,256);
    const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/webp',0.86));
    if (!blob || blob.type!=='image/webp') throw new AppError('AVATAR_INVALID');
    return blob;
  } finally { URL.revokeObjectURL(url); }
}
