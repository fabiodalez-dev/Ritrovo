# Review di Ritrovo e piano di miglioramento

Data: 13 ottobre 2026. Versione esaminata: 0.2.0 (commit `dcf48dad`). Oggetto: l'app macOS `macos/Ritrovo`, front-end SwiftUI del motore PhotoRec incluso nel bundle.

## Stato con la 0.3.0

Tutti i difetti qui sotto sono corretti nella 0.3.0, e la release ne corregge altri tre trovati durante il lavoro. I test della review passano tutti (nessun `knownIssue` rimasto) e sono affiancati da 7 test di regressione, per un totale di 57.

- **Ripresa di un recupero da un'immagine con spazi nel percorso.** Il motore divide la riga della sessione al primo spazio, e Ritrovo leggeva il dispositivo allo stesso modo. Ogni copia fatta da Ritrovo vive in «Immagine <nome> <data>/disco.img», quindi un recupero da una copia non si poteva riprendere. Ora la sessione viene letta fino alla parola chiave della tabella e il motore riceve un collegamento senza spazi nella cartella privata dell'app.
- **Motore bloccato dall'unformat su una FAT senza sottocartelle.** Il messaggio «Can't find FAT cluster size» apriva un menu che aspetta un tasto; in modalità batch, con stdin chiuso, il motore girava a vuoto per sempre. In modalità batch il messaggio va ora nel registro.
- **Unformat sempre rifiutato sulle partizioni MBR standard.** Il controllo «FAT filesystem was beginning before the actual partition» confrontava un numero di settore con un offset in byte. Con la partizione al settore 63 l'unformat non partiva mai. Il difetto è presente anche nel PhotoRec originale.

Rimangono fuori dalla release, per un vincolo esterno, la firma con Developer ID, la notarizzazione e l'helper privilegiato `SMAppService`: richiedono un account Apple Developer. La localizzazione resta un lavoro futuro: l'app oggi è solo in italiano.

## Giudizio sintetico

L'app è in ottimo stato per un progetto alla versione 0.2. L'architettura separa bene la logica pura (`RitrovoCore`, senza AppKit) dalla UI, e quasi tutta la logica rischiosa — costruzione della riga di comando del motore, parsing del log JSON, scansione delle cartelle, organizzazione e deduplica — è già isolata e testabile. La sicurezza del percorso privilegiato è pensata con cura: root serve solo a leggere un disco fisico, lo script `ritrovo-run.sh` crea lui la cartella, rifiuta symlink e cartelle preesistenti, e le variabili `RITROVO_*` sono ignorate quando si gira da root. Il testo è coerente, calmo e in italiano, in linea con `PRODUCT.md` e `DESIGN.md`.

Ho scritto 50 test nuovi in `Tests/RitrovoCoreTests/ReviewTests.swift`, agganciati al runner esistente. 45 passano; 5 falliscono di proposito e documentano altrettanti difetti reali (marcati `knownIssue`): quando li correggi, il runner segnala "UNEXPECTED PASS" e togli il flag. La suite di base preesistente continua a passare.

```bash
cd macos/Ritrovo && swift run RitrovoCoreTests
```

## Difetti trovati, in ordine di priorità

### 1. Le impostazioni salvate si azzerano a ogni nuova opzione (medio) — test J5

`RecoveryOptions` usa il `Codable` sintetizzato. La decodifica sintetizzata di Swift pretende tutte le chiavi: appena aggiungi un'opzione nuova (come è successo con `verboseLog`), il decode di un file salvato da una versione precedente lancia `keyNotFound`. In `AppModel.init` la decodifica è dentro un `try?`, quindi l'errore è silenzioso e l'utente si ritrova le impostazioni riportate ai valori predefiniti senza capire perché. È il difetto con più probabilità di colpire un utente reale, a ogni aggiornamento che aggiunge un'opzione.

Correzione: scrivere un `init(from:)` manuale che usa `decodeIfPresent` con un valore di riserva per ogni campo. Così i file vecchi si leggono e i campi nuovi prendono il predefinito.

### 2. Metà del catalogo finisce nella categoria «Altro» (medio) — test B2

La mappa `FileCategory` conosce circa 80 estensioni, ma il catalogo generato dai sorgenti ne ha 349: 269 cadono in «Altro». Ne risentono le schede per categoria della galleria e l'organizzazione «Per tipo», che ammassano in «Altro» molti formati recuperabili e riconoscibili (foto come `exr`, `pnm`, `hdr`; progetti come `dwg`, `dxf`; immagini disco come `vmdk`, `vdi`, `e01`, `wim`). Non è un bug funzionale ma abbassa la qualità percepita proprio nella schermata in cui l'utente giudica il risultato.

Correzione: ampliare le liste in `Results.swift`. Una strada più solida è derivarle da `formats.json`, aggiungendo una colonna di categoria a `gen_formats.py` o mappando per gruppi noti del motore.

### 3. «Ultimi trovati» non ordina per data (medio-basso) — test C2

`ResultSort.newest` restituisce la lista nell'ordine di ingresso senza ordinare per `modified`. In `ResultsView` l'ingresso è `allFiles`, ordinata per percorso: quindi la voce «Ultimi trovati» mostra l'ordine dei percorsi, non quello temporale. Durante un recupero attivo l'ordine capita giusto (i nuovi file sono inseriti in testa), e questo nasconde il difetto, ma la schermata dei risultati mente sull'etichetta.

Correzione: ordinare esplicitamente per `modified` decrescente nel ramo `.newest`.

### 4. Deduplica fragile sui percorsi con symlink (basso) — test I5

`Organizer.moveDuplicates` esclude la cartella «Duplicati» confrontando le stringhe dei percorsi (`hasPrefix(dupDir.path)`). Ma `allFiles` restituisce i percorsi con i symlink risolti dall'enumeratore di `FileManager` (per esempio `/private/var/...`), mentre `dupDir.path` resta non risolto (`/var/...`): su una destinazione raggiunta attraverso un symlink l'esclusione non scatta, e una seconda esecuzione della deduplica rielabora i file già spostati, arrivando a spostare anche gli originali. Le destinazioni reali (Download, dischi esterni in `/Volumes`) non passano da symlink, quindi l'impatto pratico è limitato, ma la logica è fragile.

Correzione: confrontare URL standardizzati (`resolvingSymlinksInPath` o `standardizedFileURL` su entrambi i lati), oppure ragionare sul rapporto di parentela tra URL anziché su prefissi di stringa.

### 5. Il nome del file system può essere sbagliato nel titolo della partizione (basso) — test D2

`EnginePartition.fileSystem` prende la terza parola della riga di descrizione del motore. Per una riga come `HPFS - NTFS` mostra `HPFS` nel titolo della partizione. È solo cosmetico: le decisioni funzionali (`isFAT`, `isExtFamily`, `supportsFreeSpace`) usano descrizione e `info` in minuscolo e restano corrette.

Correzione: usare il campo `info` (che riporta `NTFS, blocksize=...`) per il nome mostrato, o riconoscere i file system con un piccolo dizionario invece che per posizione.

### Osservazioni minori (senza test dedicato)

- **Ancora dello shift-click nella galleria** (`Gallery.swift:70`): l'ancora della selezione a intervallo è `selection.first`, ma `selection` è un `Set` non ordinato, quindi con più file già selezionati l'estremo dell'intervallo è arbitrario. Conviene tenere un'ancora esplicita (l'ultimo elemento cliccato).
- **Localizzazione**: tutte le stringhe sono letterali Swift, non passano da `NSLocalizedString`/catalogo. Oggi è solo italiano, ma aggiungere una lingua richiederà di toccare il codice ovunque.
- **Firma ad-hoc**: l'app non è firmata con un Developer ID né notarizzata, quindi su un altro Mac il primo avvio richiede il menu contestuale «Apri». È già scritto nel README come limite noto.
- **Copertura**: `RitrovoCore` è coperto bene; `AppModel`, `Engine` e le viste non hanno test unitari (solo il self-test end-to-end, che però richiede un'immagine disco e l'app installata).

## Cosa funziona bene e va conservato

La costruzione della riga `/cmd` combacia esattamente con le parole chiave accettate dal motore (verificato in `phcli.c`, `poptions.c`, `geometry.c`, `part*.c`): il test E1 confronta ogni parola emessa con l'elenco reale delle parole chiave del motore. Il parsing del log JSON regge campi mancanti, tipi inattesi e righe con `CR LF`. La lettura incrementale del log gestisce correttamente le righe spezzate su più scritture. Lo smoothing della velocità ignora i campioni troppo vicini e i salti all'indietro, evitando numeri assurdi. Lo `Shell.quote` è stato verificato con `/bin/sh` reale su stringhe con apici, spazi e `$`.

## Piano di miglioramento

### Subito (correttezza, poco codice)
1. `init(from:)` manuale per `RecoveryOptions` con `decodeIfPresent` (difetto 1).
2. Ordinare per data in `ResultSort.newest` (difetto 3).
3. Standardizzare i percorsi in `moveDuplicates` e in `allFiles` (difetto 4).
4. Ancora esplicita per lo shift-click nella galleria (osservazione minore).

### A breve (qualità percepita)
5. Completare la mappa delle categorie, meglio se generandola da `formats.json` (difetto 2).
6. Nome del file system dal campo `info` nel titolo della partizione (difetto 5).
7. Estendere il self-test con fixture committate (una piccola immagine FAT e una generica) così da poterlo far girare in automatico, non solo a mano.

### A medio termine (distribuzione e robustezza)
8. Firma con Developer ID e notarizzazione, per togliere l'attrito del primo avvio.
9. Helper privilegiato con `SMAppService`, verificato per firma, al posto dello script eseguito da root dal bundle (già indicato come fix proprio nel README).
10. Estrarre le stringhe in un catalogo di localizzazione, in vista di una seconda lingua.
11. Primi test su `AppModel` (selezione, `canStart`, applicazione dei default di partizione) rendendo iniettabili i servizi disco.

## I 50 test

Sono in `Tests/RitrovoCoreTests/ReviewTests.swift`, raggruppati per area. Ogni test ha un nome; i 5 `knownIssue` corrispondono ai difetti 1–5 qui sopra.

| Gruppo | Test | Copre |
|---|---|---|
| A. Catalogo formati | A1–A3, A5–A7 | merge, ordinamento, descrizioni, caricamento, errori, ricerca |
| B. Categorie | B1–B3, B5 | classificazione, immagini decodificabili, RecoveredFile |
| C. Filtri risultati | C1–C4 | ricerca, ordinamenti |
| D. Partizioni | D1–D4 | disco intero, NTFS, exFAT, ext4 |
| E. Riga /cmd | E1–E7 | parole chiave reali, geometria, ext2, fileopt, tabelle, nessuno spazio |
| F. Eventi JSON | F1–F4, F6 | campi mancanti, frazione, righe rotte, disk_info, tempi e stat |
| G. Lettura incrementale | G1–G2 | file assente/vuoto, righe spezzate |
| H. Scansione cartelle | H2–H4 | ignorati, cartelle chiuse, allFiles |
| I. Strumenti risultati | I1–I7 | nome unico, organizza, duplicati, CSV, EXIF |
| J. Velocità/cronologia/opzioni | J1–J5 | smoothing, media mobile, cronologia, Codable |
| K. Privilegi e shell | K1–K3 | dispositivo grezzo, quoting verificato con /bin/sh |
