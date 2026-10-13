# SakAccounts on a phone

Open `https://accounts.saksolution.com/` and sign in. On Android Chrome, use **Install app** when shown, or choose **Add to Home screen** from the browser menu. On iPhone Safari, use **Share > Add to Home Screen**. The installed shortcut opens the quick capture screen.

## Fast capture

- **Take photo** opens the phone camera. **Upload receipt** accepts a saved image or PDF. Images are read on the device with bundled Tesseract OCR files. JPEG, PNG, WebP, HEIC and HEIF can be stored as private attachments; OCR depends on the browser being able to decode the image. The photo is attached privately when the reviewed entry is saved. PDF attachment does not extract text in this flow.
- Paste a bank or card SMS and choose **Fill from message**, or share text to SakAccounts from a supported mobile share menu. The parser suggests amount, date, merchant, reference, category and payment type where identifiable. It never guesses the business entity or a specific funding account. Check every field before saving.
- The default form shows amount, merchant, category, entity, date and payment. Reference and due date are optional; stock, splits, assets and financing remain under **More accounting options**.

## Offline behavior

The PWA caches its app shell, icons and local OCR files. A previously signed-in device can keep a capture draft in its browser storage while offline, including a selected photo. Drafts are local to that browser profile. They are **not** financial postings and do not affect balances. Reconnect, restore the draft, check it, and press **Save entry** to post it through the normal authenticated Supabase function. A fresh device still needs an online sign-in. Do not clear browser site data before posting a draft.

Supabase data, account balances and Auth are not cached by the service worker. The app requires a connection to post and refresh financial records. No paid AI service is used for photo or SMS extraction. OCR is an aid, not proof that a receipt or SMS is correct.

## Deployment checks

Check `/manifest.webmanifest`, `/sw.js`, `/icons/icon-192.png`, `/icons/icon-512.png`, `/ocr/worker.min.js`, `/ocr/lang/eng.traineddata.gz`, and `/healthz` over HTTPS. Test installation and camera access on a real phone. Roll back the app by selecting the prior release in `/opt/sakaccounts/releases`; no new database migration is required for this UI release.
