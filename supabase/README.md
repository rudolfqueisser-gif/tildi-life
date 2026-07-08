# Supabase-Setup für Tildi Life

## 1. Schema anlegen
Im Supabase-Dashboard: **SQL Editor → New query**, Inhalt von `schema.sql` einfügen, **Run**.
Das Skript ist gefahrlos mehrfach ausführbar (idempotent).

## 2. Auth-Einstellungen
**Authentication → Providers → Email**: "Email OTP / Magic Link" aktivieren, Passwort-Login kann
deaktiviert bleiben (Magic Link reicht, kein Passwort-Handling nötig).

**Authentication → URL Configuration**: Site URL auf die spätere App-URL setzen (z. B. GitHub Pages-
oder Vercel-URL), damit die Magic-Link-E-Mails korrekt zurückverlinken.

## 3. Wie der Mehrbenutzer-Zugriff funktioniert
- Wer ein Kind (`children`-Zeile) anlegt, wird per Trigger automatisch als `elternteil` mit
  vollem Zugriff eingetragen.
- Ein `elternteil` kann weitere Personen einladen: neue Zeile in `memberships` mit
  `invited_email`, `role`, `status='pending'`, `user_id=NULL`.
- Meldet sich diese Person erstmals per Magic Link an, aktualisiert der Client die passende
  `pending`-Zeile auf `status='active'` und `user_id=auth.uid()` (kein Server/Edge-Function nötig,
  die RLS-Policy `memberships_claim_update` erlaubt das gezielt für die eigene E-Mail-Adresse).
- Rollen: `elternteil` (voller Zugriff inkl. Einladen/Entfernen), `betreuer_einrichtung`,
  `betreuer_privat`, `arzt` (aktuell alle mit gleichem Lese-/Schreibzugriff auf die Pflegedaten,
  aber ohne Verwaltungsrechte für `memberships`). Feinere Rechte pro Rolle lassen sich später
  einfach ergänzen, falls gewünscht.

## Bewusst noch nicht enthalten
- **Fotos** (Dokument-/Rezept-Fotos, Kinderfoto) liegen aktuell nur lokal in IndexedDB und
  werden **nicht** mitsynchronisiert. Das würde einen Supabase-Storage-Bucket + Upload-Code
  brauchen – kommt als eigener Schritt, sobald der Rest steht.
- Feingranulare Rollen-Rechte (z. B. Arzt nur lesend) – aktuell haben alle aktiven Mitglieder
  gleiche Lese-/Schreibrechte auf die Pflegedaten, passend zum bisherigen App-Verhalten.
