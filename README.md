# RC_OPBG_4

Script PowerShell per cercare computer in Active Directory, Microsoft Entra ID, Microsoft Intune e GLPI, e per gestire la rimozione con il tool esistente.

## Computer Explorer: prima console di ricerca

`Start-ComputerExplorer.ps1` apre una finestra con ricerca per frammento, griglia colorata e dettaglio degli oggetti. Usa i cinque DC configurati e riunisce tutti i nomi trovati in AD, Entra, Intune Windows e GLPI. Un nome presente in una sola fonte compare comunque nella lista.

Le colonne mostrano presenza AD, conteggi Entra/Intune/GLPI, stato GLPI, percorso AD e segnalazioni su GUID, percorsi, seriali o DeviceId discordanti. Accanto a ogni fonte compare la relativa data: modifica AD, attività Entra, check-in Intune e inventario GLPI. Il numero di DC verificati rimane nel dettaglio e nel suggerimento della cella AD. Il dettaglio conserva le singole registrazioni e i relativi ID. Nomi GLPI con suffissi fra parentesi restano distinti.

| Colore | AD | Entra / Intune / GLPI |
|---|---|---|
| Verde | Presente su tutti i DC configurati | Una registrazione |
| Giallo | Presente su alcuni DC, tutti verificati | Più registrazioni dello stesso nome |
| Rosso | Assente, tutti i DC verificati | Zero registrazioni, ricerca completata |
| Grigio / ? | Verifica incompleta o fonte esclusa | Errore, fonte esclusa o lettura in attesa |

Le date usano il formato `dd/MM/yyyy HH:mm` e si ordinano cronologicamente. Con più registrazioni viene mostrata la data valida più recente; il dettaglio conserva i dati di ogni oggetto e di ogni DC. Una data assente o non valida appare come **—**.

| Colonna data | Campo letto |
|---|---|
| Modifica AD | `Modified` (alias di `whenChanged`), massimo fra i DC letti |
| Attività Entra | `approximateLastSignInDateTime`, attività approssimativa |
| Check-in Intune | `lastSyncDateTime`, ultima sincronizzazione riuscita |
| Inventario GLPI | `last_inventory_update`, distinta dalla modifica della scheda `date_mod` |

Le date Graph con offset vengono convertite nell'ora locale del PC. GLPI restituisce normalmente una data senza offset: viene conservato l'orario del server. La data AD è propria di ciascun DC e può differire fra le repliche. Queste colonne riportano gli eventi del dispositivo; la scheda **Stato fonti e orari** continua a riportare l'orario della lettura eseguita dalla console.

La console permette ora anche la rimozione delle righe selezionate da AD, Entra e Intune. GLPI rimane una fonte di consultazione. Il file `Remove-Computer-FullTool.ps1` resta disponibile come tool precedente.

### Avvio sul PC Windows

Dal repository, già sul branch `feature/computer-explorer`:

```powershell
git status
git pull --ff-only
powershell.exe -NoProfile -STA -File .\Start-ComputerExplorer.ps1
```

Riutilizza `computer-explorer.config.local.json`, già configurato per le prove AD e GLPI. Se manca, copiarlo dal modello e impostare URL GLPI, Enabled e UseAppToken come descritto sotto. Il modello viene lasciato disabilitato per GLPI e non contiene token.

Scrivere ad esempio `PORT-` e premere **Cerca**. I token GLPI vengono letti automaticamente dal `.env` nella cartella degli script. Se il file manca o i token richiesti sono vuoti, si apre il prompt della finestra. **Token GLPI** permette una sostituzione temporanea per la finestra corrente. Graph riutilizza la sessione disponibile nello stesso processo; se manca o richiede ambiti aggiuntivi, apre il login interattivo. I token GLPI non vanno inseriti nel JSON o nel repository.

Le interrogazioni lavorano in un runspace separato: la finestra resta disponibile e la griglia si aggiorna dopo ogni fonte. **Interrompi** annulla la lettura; le fonti ancora in attesa restano non verificate. Le caselle AD / Entra / Intune / GLPI scelgono le fonti da interrogare.

La prima lettura cloud raccoglie tutte le pagine dei campi necessari, poi applica il confronto contiene senza distinzione fra maiuscole e minuscole. La cache completa dura `Search.CloudCacheMinutes` (predefinito 5; 0 la disabilita), resta in memoria e viene separata per tenant, client, account, autenticazione e ambiti. **Rileggi cloud** forza una nuova lettura. La scheda **Stato fonti e orari** indica esiti, errori, orari e utilizzo della cache. AD e GLPI vengono riletti a ogni ricerca; GLPI può richiedere più tempo con molti risultati perché legge le schede e gli stati.

Requisiti della console: Windows PowerShell 5.1, RSAT `ActiveDirectory`, modulo `Microsoft.Graph.Authentication` e accessi aziendali alle fonti. Il modulo Graph può essere una dipendenza già presente del tool originale. Se manca, installarlo dalla stessa Windows PowerShell usata per avviare la console:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

La console accetta gli ambiti di lettura e quelli più ampi già utilizzati. Se serve autenticarsi, mantiene gli ambiti autorizzati del progetto: `Directory.AccessAsUser.All` per Entra e `DeviceManagementManagedDevices.ReadWrite.All` per Intune. Una sessione applicativa preconfigurata viene conservata; le risposte API ne verificano i diritti effettivi.

### Token GLPI nel file .env

Creare una sola volta il file locale dal modello, senza sovrascrivere un `.env` già compilato:

```powershell
if (-not (Test-Path -LiteralPath .\.env)) { Copy-Item .\.env.example .\.env }
notepad .\.env
```

Inserire i token dopo il segno `=`:

```dotenv
GLPI_USER_TOKEN=il_tuo_user_token
GLPI_APP_TOKEN=il_tuo_app_token
```

L'App token può restare vuoto quando `Glpi.UseAppToken` è `false`. Il file `.env` contiene i token in chiaro e rimane locale, escluso da Git insieme a `.env.*`; soltanto `.env.example` è versionato. Non inserire i token reali nel modello. Sono supportati commenti, spazi e valori tra virgolette; variabili ed espressioni restano testo letterale. Un file malformato produce un errore con il numero di riga, senza mostrare il valore.

Il caricamento automatico è disponibile nella finestra e in `Test-GlpiLookup.ps1`. Una volta letti, i token vengono conservati come SecureString in memoria. Dopo aver modificato il `.env`, chiudere e riaprire la finestra. Gli inserimenti manuali non modificano il file.

### Selezione ed eliminazione

La legenda superiore è rimossa. Le colonne AD, Modifica AD, Entra ID, Attività Entra, Intune, Check-in Intune, GLPI e Inventario GLPI vengono dimensionate sui valori formattati e sulle intestazioni. I contatori **Risultati** e **Selezionati** sono sempre visibili.

Selezionare una o più righe con Ctrl+clic o Maiusc+clic, quindi premere **Elimina...**. La finestra delle origini propone **AD, Entra e Intune già spuntati**; si possono deselezionare le origini da mantenere. GLPI non è selezionabile per la rimozione.

**Verifica oggetti** rilegge i nomi completi senza usare la cache, verifica tutti i DC selezionati e mostra gli ID esatti nell'anteprima. Solo **Elimina definitivamente** avvia la rimozione. La cancellazione di una registrazione Windows in Intune avvia anche il ritiro dalla gestione.

Il piano vale cinque minuti, viene consumato una sola volta ed è legato alla sessione Graph. Gli ID, i nomi e gli altri dati di identità vengono ricontrollati prima delle scritture e immediatamente prima di ogni eliminazione. Oggetti nuovi o modificati dopo l'anteprima bloccano quel computer. Le duplicazioni dello stesso nome sono mostrate e incluse nell'anteprima; nomi soltanto simili e altre piattaforme Intune sono esclusi.

L'ordine è **Intune → AD sui DC → Entra**. Un errore blocca le operazioni successive per quel computer; gli altri computer proseguono. Le assenze già confermate, anche dovute alla replica AD, sono indicate come **Già assente**. Gli esiti per oggetto sono nella scheda **Esiti eliminazione**. Dopo il completamento la ricerca viene aggiornata con rilettura cloud.

**Interrompi** durante una cancellazione termina il computer corrente e salta quelli successivi. Dopo un'interruzione o un errore generale, eseguire una nuova ricerca prima di un'altra eliminazione. La chiusura normale della finestra attende lo stesso arresto.

Il modulo `ComputerExplorer.Removal.psm1` espone preparazione e applicazione del piano. Supporta `-WhatIf` per eseguire le verifiche senza cancellare.

### Verifiche eseguite

Il workflow GitHub Actions verifica parser e suite su Windows PowerShell 5.1 a ogni push. I test usano dati sintetici e API simulate: cloud, AD, GLPI, date, file `.env`, rimozioni ed errori. Lo smoke test WinForms costruisce la finestra e verifica selezione, contatori e dimensioni delle colonne senza effettuare ricerche o eliminazioni aziendali. Le verifiche precedenti sono passate anche in PowerShell 7.4.19; la suite cloud/date è stata provata con fuso Europe/Rome.

```powershell
.\tests\ComputerExplorer.Tests.ps1
.\tests\Glpi.Credentials.Tests.ps1
.\tests\ComputerExplorer.Removal.Tests.ps1
.\tests\ComputerExplorer.UI.Tests.ps1
.\tests\AD.Lookup.Tests.ps1
.\tests\GLPI.Inventory.Tests.ps1
```

AD e GLPI sono già stati provati separatamente nell'ambiente aziendale, come riportato sotto. Il 15 ottobre 2026 l'utente ha confermato il funzionamento della prima finestra. Le nuove colonne data sono state verificate con risposte simulate; la visualizzazione dei nuovi valori reali va verificata sul PC aziendale.

## Tool di rimozione esistente

- Ricerca per nome esatto sui cinque Domain Controller configurati.
- Ricerca delle occorrenze in Entra ID.
- Ricerca delle registrazioni Windows in Intune per nome e DeviceId Entra.
- Eliminazione dalle origini selezionate dopo conferma.
- Ordine di eliminazione: Intune, Active Directory, Entra ID. Un errore di eliminazione Intune interrompe le successive eliminazioni AD ed Entra.

In Intune, l'eliminazione avvia anche il ritiro del dispositivo Windows dalla gestione.

## Requisiti

- Windows PowerShell 5.1.
- Modulo `ActiveDirectory` tramite RSAT.
- Modulo `Microsoft.Graph.Identity.DirectoryManagement` e accesso Graph autorizzato.
- Ambito Graph Entra: `Directory.AccessAsUser.All`.
- Ambito Graph Intune: `DeviceManagementManagedDevices.ReadWrite.All` e un ruolo Intune adeguato.

Il file principale è `Remove-Computer-FullTool.ps1`.

## Lavorare con Git

Prima di iniziare, controllare lo stato. Con la cartella senza modifiche locali, scaricare gli aggiornamenti:

```powershell
git status
git pull --ff-only
```

Dopo aver modificato e verificato lo script:

```powershell
git diff -- Remove-Computer-FullTool.ps1
git add -- Remove-Computer-FullTool.ps1
git diff --cached --stat
git commit -m "Descrizione della modifica"
git push
```

`add` prepara il contenuto, `commit` lo salva nella cronologia locale, `push` invia i commit a GitHub e `pull` riceve gli aggiornamenti.

Per vedere gli ultimi salvataggi:

```powershell
git log --oneline -5
```

## Recuperare una versione salvata

Il commit `ed33c0c` contiene il primo script importato. Per esportare una copia di quella versione nella cartella temporanea di Windows:

```powershell
git archive --format=zip --output="$env:TEMP\RC_OPBG_4-ed33c0c.zip" ed33c0c
```

Sostituire `ed33c0c` con l'identificatore del commit desiderato, ricavato da `git log`. Lo ZIP contiene i file presenti in quel commit; la copia di lavoro corrente resta disponibile.

## Configurazioni

I token si inseriscono nelle richieste di autenticazione o si conservano in file locali esclusi da Git. Il file `.gitignore` contiene le regole di esclusione.

## Connettore GLPI nel branch di sviluppo

`GLPI.Inventory.psm1` ricerca i Computer per frammento del nome e restituisce ID, stato, seriale e numero inventario. Gli stati vengono letti dal server GLPI.

La configurazione usata automaticamente dal test è `computer-explorer.config.local.json`, esclusa da Git. Se esiste già un JSON funzionante, copiarlo qui con questo nome per mantenere l'URL corretto.

In alternativa, creare la configurazione dal modello:

```powershell
Copy-Item .\computer-explorer.config.example.json .\computer-explorer.config.local.json
notepad .\computer-explorer.config.local.json
```

Nel file locale impostare `Glpi.Enabled` su `true`, inserire in `Glpi.BaseUri` l'URL corretto di `apirest.php` e verificare `Glpi.UseAppToken`. I token vengono letti dal `.env`; se manca o è incompleto, vengono richiesti nei prompt.

Per provare la ricerca:

```powershell
.\Test-GlpiLookup.ps1 -NameFragment "PORT-"
```

Per usare una configurazione in un altro percorso, passare `-ConfigPath`. Per eseguire i test con risposte API simulate:

```powershell
.\tests\GLPI.Inventory.Tests.ps1
```

Le prove simulate coprono risultati singoli e multipli, formati degli ID, paginazione e chiusura della sessione su errore. La prova del 13 ottobre 2026 sul GLPI aziendale ha restituito 528 record con ID distinti e validi, 527 nomi distinti e cinque stati. Un nome ha due registrazioni con seriali diversi; questi record resteranno distinti nel dettaglio. Tutti i risultati della prova hanno EntityId 0.

Il [progetto Computer Explorer](docs/Computer-Explorer.md) descrive la console e i passi successivi.

## Prova della ricerca AD parziale

`Test-AdLookup.ps1` cerca il frammento in nome, nome DNS e sAMAccountName sui DC configurati. Mostra l'esito di ogni DC, le presenze rispetto al totale, i DC verificati e il percorso del contenitore/OU letto da `CanonicalName`.

Usa lo stesso `computer-explorer.config.local.json` del test GLPI:

```powershell
.\Test-AdLookup.ps1 -NameFragment "PORT-" -Verbose
```

`Verde` indica presenza su tutti i DC configurati, `Giallo` una presenza parziale dopo aver verificato tutti i DC e `Grigio` un'interrogazione incompleta. Il test mostra i colori come testo; la console li applica alle celle della griglia.

GUID o percorsi diversi fra DC vengono segnalati. Un DC che restituisce un errore non viene contato come verificato. Il test effettua soltanto letture AD.

Per i test con risposte AD simulate:

```powershell
.\tests\AD.Lookup.Tests.ps1
```

Questi test coprono presenza su tutti o alcuni DC, DC indisponibile, nessun risultato, nomi con maiuscole diverse, GUID e percorsi differenti, caratteri escaped e dati non validi. Nell'estratto della prova reale del 13 ottobre 2026 tutte le 14 righe mostrate riportano 5/5 presenti, 5/5 verificati, percorsi valorizzati e nessun GUID discordante. Il campione non permette di descrivere le righe non condivise.

## Sviluppi previsti

Verificare i nuovi comandi sul PC aziendale e rifinire le associazioni fra sorgenti. La scelta del contesto entità/profilo GLPI resta da progettare; oggi si usa quello predefinito dell'utente API.

