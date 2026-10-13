-- Mobile cameras may save HEIC/HEIF or WebP instead of JPEG.
update storage.buckets
set allowed_mime_types = (
  select array_agg(distinct mime)
  from unnest(allowed_mime_types || array['image/heic','image/heif','image/webp']::text[]) as mime
)
where id='sakaccounts-private';
