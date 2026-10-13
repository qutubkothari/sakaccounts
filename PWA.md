# SakAccounts on a phone

Open `https://accounts.saksolution.com/` and sign in. On Android Chrome, use **Install app** when shown, or choose **Add to Home screen** from the browser menu. On iPhone Safari, use **Share > Add to Home Screen**. The installed shortcut opens the quick capture screen.

## Fast capture

- **Take photo** opens the phone camera. **Upload PDF or photo** accepts a JPG, PNG or PDF up to 15 MB. Images are read on the device with bundled Tesseract OCR files. Text PDFs are read locally; a scanned PDF falls back to OCR on its first page. The document is attached privately when the reviewed entry is saved. Invoice capture uses the same reader and suggests supplier, number, date and total. Always check the suggestions before saving.
- Paste a bank or card SMS and choose **Fill from message**, or share text to SakAccounts from a supported mobile share menu. The parser suggests amount, date, merchant, reference, category and payment type where identifiable. It never guesses the business entity or a specific funding account. Check every field before saving.
- The default form shows amount, merchant, category, entity, date and payment. Reference and due date are optional; stock, splits, assets and financing remain under **More accounting options**.

## Offline behavior

The PWA caches its app shell, icons and local OCR files. A previously signed-in device can keep a capture draft in its browser storage while offline, including a selected photo. Drafts are local to that browser profile. They are **not** financial postings and do not affect balances. Reconnect, restore the draft, check it, and press **Save entry** to post it through the normal authenticated Supabase function. A fresh device still needs an online sign-in. Do not clear browser site data before posting a draft.

Supabase data, account balances and Auth are not cached by the service worker. The app requires a connection to post and refresh financial records. No paid AI service is used for photo or SMS extraction. OCR is an aid, not proof that a receipt or SMS is correct.

## Daily review and alerts

The dashboard lists negative recorded bank/cash balances, overdue bills, statement discrepancies, unreconciled rows, possible repeated expenses, missing documents on larger expenses, budget overruns, and sharp category increases. Each item leads to a relevant screen. These are review signals; a flagged transaction is not proof of a loss.

Choose **Enable background alerts** on each device and accept the browser notification prompt. SakAccounts sends a daily review around 9 a.m. in the configured reporting timezone, and sends an alert when urgent recorded balances or overdue bills change. The notification contains a count, not financial details. **Turn off alerts** removes that device's push subscription. Browser and operating-system notification settings can still suppress delivery. The server push worker uses a private Supabase service key and VAPID private key; neither is included in the PWA bundle.

## Deployment checks

Check `/manifest.webmanifest`, `/sw.js`, `/push-handler.js`, `/icons/icon-192.png`, `/icons/icon-512.png`, `/ocr/worker.min.js`, `/ocr/lang/eng.traineddata.gz`, and `/healthz` over HTTPS. Test installation, camera and notifications on a real phone. Roll back the app by selecting the prior release in `/opt/sakaccounts/releases`; the additive push subscription migration can remain in place.
