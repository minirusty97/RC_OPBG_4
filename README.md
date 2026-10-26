# Assistente IT

Script PowerShell per cercare computer in Active Directory, Microsoft Entra ID, Microsoft Intune e GLPI, e per gestire la rimozione con il tool esistente.

## Assistente IT: installazione e distribuzione

La versione funzionante di Computer Explorer è integrata in `main`. La suite aggiunge un punto di avvio comune e un installer per utente, predisposto per ospitare altri moduli di gestione Intune.

I colleghi autorizzati al repository privato scaricano il file **Assistente-IT-Setup-VERSIONE.exe** da [Releases](https://github.com/minirusty97/RC_OPBG_4/releases/latest), installano e aprono **Assistente IT**. Da **Impostazioni** configurano GLPI e i DC; Graph è incluso nel setup. Per AD serve RSAT/ActiveDirectory sul PC.

Configurazione e `.env` personali restano in `%LOCALAPPDATA%\AssistenteIT\Config`, separati dal programma e conservati durante gli aggiornamenti. Il setup 1.0.2 migra automaticamente i dati e l’installazione dalle versioni 1.0.0 e 1.0.1. I colleghi non devono installare Git. Il workflow costruisce e prova il setup, quindi pubblica una nuova release dopo il merge in `main` quando aumenta `Version` in `assistente-it.json`. Dalla 1.0.8 la finestra controlla le release pubbliche in background e offre Aggiorna; la prima versione con OTA va installata manualmente.

Vedere [installazione, aggiornamenti, build e nuovi moduli](docs/Installazione-AssistenteIT.md). Per avviare la suite dai sorgenti:

```powershell
powershell.exe -NoProfile -STA -File .\Start-AssistenteIT.ps1
```

## Computer Explorer: console di ricerca

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

Scrivere ad esempio `PORT-` e premere **Cerca**. I token GLPI vengono letti dall’archivio cifrato personale; un `.env` precedente viene migrato alla prima lettura. Se mancano i token richiesti, si apre il prompt della finestra. **Token GLPI** permette di aggiornarli e salvarli cifrati. Graph riutilizza la sessione disponibile nello stesso processo; se manca o richiede ambiti aggiuntivi, mostra il codice di accesso Microsoft e apre il browser esterno. I token GLPI non vanno inseriti nel JSON o nel repository.

I cinque DC vengono interrogati in sequenza da un unico lettore AD dedicato. In parallelo ad AD procedono GLPI, Entra e Intune, per un massimo di quattro lettori attivi. Un solo lavoro prepara la sessione Graph, poi Entra e Intune partono insieme; AD e GLPI possono già procedere durante il login. La finestra riceve i risultati man mano, senza aspettare le fonti più lente. Gli aggiornamenti arrivati nello stesso intervallo vengono riuniti prima di ridisegnare la griglia. **Interrompi** annulla tutti i lettori della ricerca; le fonti ancora in attesa restano non verificate. I lettori vengono arrestati e disposti prima di consentire una nuova operazione. Le caselle AD / Entra / Intune / GLPI scelgono le fonti da interrogare. Quattro indicatori permanenti in basso mostrano lo stato di ogni fonte: verde se terminata correttamente, rosso se terminata con errori, giallo se in corso e grigio se esclusa. AD indica anche i DC completati. La ricerca si conclude quando tutte le fonti selezionate hanno un esito finale, compresi gli errori; a quel punto si può agire sui risultati selezionati. La verifica prima della cancellazione continua a controllare le fonti scelte.

La prima lettura cloud raccoglie tutte le pagine dei campi necessari, poi applica il confronto contiene senza distinzione fra maiuscole e minuscole. La cache completa dura `Search.CloudCacheMinutes` (predefinito 5; 0 la disabilita), resta in memoria e viene separata per tenant, client, account, autenticazione e ambiti. **Rileggi cloud** forza una nuova lettura. La scheda **Stato fonti e orari** indica esiti, errori, orari e utilizzo della cache. La cache cloud completa è condivisa fra i lettori e sopravvive alle ricerche nella stessa finestra. AD e GLPI vengono riletti a ogni ricerca; GLPI può richiedere più tempo con molti risultati perché legge le schede e gli stati. Le pagine di ogni API e le richieste della sessione GLPI restano ordinate; il parallelismo riguarda le fonti e i DC. Il tempo finale dipende dalla fonte più lenta e dai tempi di autenticazione, quindi non viene garantito un fattore di accelerazione.

Requisiti della console: Windows PowerShell 5.1, RSAT `ActiveDirectory`, modulo `Microsoft.Graph.Authentication` e accessi aziendali alle fonti. Il modulo Graph può essere una dipendenza già presente del tool originale. Se manca, installarlo dalla stessa Windows PowerShell usata per avviare la console:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

La console accetta gli ambiti di lettura e quelli più ampi già utilizzati. Se serve autenticarsi, mantiene gli ambiti autorizzati del progetto: `Directory.AccessAsUser.All` per Entra e `DeviceManagementManagedDevices.ReadWrite.All` per Intune. Una sessione applicativa preconfigurata viene conservata; le risposte API ne verificano i diritti effettivi.

### Token GLPI

Inserire i token nelle **Impostazioni** della suite o tramite **Token GLPI** nella finestra Computer Explorer. Vengono salvati cifrati con Windows DPAPI CurrentUser, nel file `glpi-credentials.dpapi.json` accanto al `.env` configurato. L’App token non è richiesto se `Glpi.UseAppToken` è `false`, ma un token già salvato viene conservato.

Il `.env` è mantenuto come formato di importazione dalle versioni precedenti: dopo una scrittura e rilettura riuscita dell’archivio cifrato, le righe dei token vengono rimosse. Commenti e altre variabili rimangono. Il parser non esegue espressioni e rifiuta duplicati o righe malformate senza mostrare valori. Non inserire token nel JSON, nel modello `.env.example` o nel repository.

Il lettore è condiviso con `Test-GlpiLookup.ps1`. La finestra conserva SecureString in memoria fino alla chiusura. Per aggiornare i token già caricati usare il pulsante Token GLPI o chiudere e riaprire la finestra.

### Selezione ed eliminazione

La legenda superiore è rimossa. Le colonne AD, Modifica AD, Entra ID, Attività Entra, Intune, Check-in Intune, GLPI e Inventario GLPI vengono dimensionate sui valori formattati e sulle intestazioni. I contatori **Risultati** e **Selezionati** sono sempre visibili.

Selezionare una o più righe con Ctrl+clic o Maiusc+clic, quindi premere **Elimina...**. La finestra delle origini propone **AD, Entra e Intune già spuntati**; si possono deselezionare le origini da mantenere. GLPI non è selezionabile per la rimozione.

**Verifica oggetti** rilegge i nomi completi senza usare la cache, verifica tutti i DC selezionati e mostra gli ID esatti nell'anteprima. Solo **Elimina definitivamente** avvia la rimozione. La cancellazione di una registrazione Windows in Intune avvia anche il ritiro dalla gestione.

Il piano vale cinque minuti, viene consumato una sola volta ed è legato alla sessione Graph. Gli ID, i nomi e gli altri dati di identità vengono ricontrollati prima delle scritture e immediatamente prima di ogni eliminazione. Oggetti nuovi o modificati dopo l'anteprima bloccano quel computer. Le duplicazioni dello stesso nome sono mostrate e incluse nell'anteprima; nomi soltanto simili e altre piattaforme Intune sono esclusi.

L'ordine è **Intune → AD sui DC → Entra**. Un errore blocca le operazioni successive per quel computer; gli altri computer proseguono. Le assenze già confermate, anche dovute alla replica AD, sono indicate come **Già assente**. Gli esiti per oggetto sono nella scheda **Esiti eliminazione**. Dopo il completamento la ricerca viene aggiornata con rilettura cloud.

**Interrompi** durante una cancellazione termina il computer corrente e salta quelli successivi. Dopo un'interruzione o un errore generale, eseguire una nuova ricerca prima di un'altra eliminazione. La chiusura normale della finestra attende lo stesso arresto.

Il modulo `ComputerExplorer.Removal.psm1` espone preparazione e applicazione del piano. Supporta `-WhatIf` per eseguire le verifiche senza cancellare.

### Verifiche eseguite

Il workflow GitHub Actions verifica parser e suite su Windows PowerShell 5.1 a ogni push. I test usano dati sintetici e API simulate: cloud, AD, GLPI, date, file `.env`, rimozioni ed errori. Le prove di concorrenza usano barriere per verificare un solo DC attivo per volta sullo stesso runspace, tre fonti indipendenti contemporanee, avanzamento per DC, errori conclusivi, login unico, cache condivisa e annullamento senza lettori residui. Lo smoke test WinForms costruisce la finestra e verifica selezione, contatori e dimensioni delle colonne senza effettuare ricerche o eliminazioni aziendali. Le verifiche precedenti sono passate anche in PowerShell 7.4.19; la suite cloud/date è stata provata con fuso Europe/Rome.

```powershell
.\tests\ComputerExplorer.Tests.ps1
.\tests\Glpi.Credentials.Tests.ps1
.\tests\ComputerExplorer.Removal.Tests.ps1
.\tests\ComputerExplorer.UI.Tests.ps1
.\tests\ComputerExplorer.Completion.Tests.ps1
.\tests\ComputerExplorer.Parallel.Tests.ps1
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

Nel file locale impostare `Glpi.Enabled` su `true`, inserire in `Glpi.BaseUri` l'URL corretto di `apirest.php` e verificare `Glpi.UseAppToken`. I token vengono letti dall’archivio DPAPI; il `.env` esistente viene migrato. Se mancano le credenziali richieste, vengono richieste nei prompt.

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


### Censimento, seriali e copia dei risultati

Le righe mantengono altezza fissa. Ctrl+C copia le righe selezionate con le intestazioni; il menu destro offre anche Copia cella senza cambiare la selezione multipla.

Censito mostra una spunta verde solo se il campo Gruppo (`groups_id`, non `groups_id_tech`) di tutte le schede GLPI dello stesso nome è esattamente CENSITO e non vi sono conflitti di seriale. Il connettore risolve il nome con GET /Group/{id}, con cache nella singola ricerca. Se il gruppo non è leggibile o le schede non concordano, mostra ? e il dettaglio nel suggerimento. Una mancata lettura del gruppo conserva gli altri dati dell’asset.

Seriale Intune e Seriale GLPI mostrano tutti i seriali significativi. Verifica seriale è Coerente solo quando entrambe le fonti sono concluse correttamente e ogni istanza ha lo stesso seriale valido. I segnaposto firmware e i valori mancanti restano Non verificabile. Seriali diversi producono Conflitto e bloccano Elimina per la selezione interessata: deselezionare le righe in conflitto per agire sulle altre. Il confronto ignora maiuscole e spazi esterni, senza rimuovere punteggiatura significativa.

La riga è un raggruppamento per nome, non un’associazione hardware certificata: AD ed Entra non forniscono qui il seriale. Nessun oggetto viene scelto o escluso automaticamente in base alla data più recente. Il controllo è una protezione dell’interfaccia sui dati letti, non una nuova verifica hardware atomica durante l’eliminazione.

### Credenziali GLPI cifrate (dalla 1.0.6)

I token vengono salvati in `glpi-credentials.dpapi.json`, accanto al `.env` configurato (nell’installazione: `%LOCALAPPDATA%\AssistenteIT\Config`). Windows DPAPI CurrentUser li protegge senza una chiave condivisa nell’app. Il salvataggio richiede Windows; su altri sistemi non viene usato un formato in chiaro.

Alla prima ricerca GLPI o al salvataggio delle impostazioni, i token presenti nel `.env` in uso vengono importati, scritti e riletti per verifica prima di rimuovere le sole righe GLPI_USER_TOKEN/GLPI_APP_TOKEN. Gli altri contenuti rimangono. Se la scrittura o la verifica falliscono, il testo originale non viene ripulito. Se archivio e .env contengono token discordanti, reinserire entrambi dalle impostazioni; un archivio illeggibile va conservato per il recupero e rimosso dal percorso attivo prima di reinserire le credenziali.

Le caselle vuote nelle impostazioni conservano i token esistenti; Token GLPI in Computer Explorer salva ora le nuove credenziali cifrate. Ogni collega configura i propri token, evitando di copiare questo archivio su un altro account o PC. L’archivio resta fuori da Git e dal pacchetto di installazione.

La migrazione interessa solo il .env del percorso attivo. Copie precedenti nel checkout, backup e Importazione-precedente non vengono eliminate automaticamente. La rimozione del testo non è una cancellazione sicura dei supporti: se i token sono stati esposti, revocarli e generarne di nuovi. DPAPI protegge il salvataggio su disco; l’app deve poterli usare durante le richieste API e non protegge da codice eseguito con il medesimo account.

### Aggiornamenti dall’app (dalla 1.0.8)

La finestra principale controlla in background `https://github.com/minirusty97/RC_OPBG_4/releases/latest/download/update.json`. Aggiornamenti ripete il controllo; Aggiorna mostra versione e note e chiede se scaricare/installare. Il feed è un asset statico pubblico, senza credenziali GitHub sui client. Una repository privata restituisce un errore di raggiungibilità, senza compromettere l’uso dei moduli.

Setup, versione, dimensione e SHA256 devono concordare con manifest e file checksum. HTTPS, host consentiti, limite dei redirect, timeout e dimensioni massime sono verificati. Il setup viene riletto e bloccato contro sostituzioni durante l’esecuzione. Queste verifiche si basano sulla fiducia nella repository GitHub pubblicatrice e in HTTPS, non sostituiscono una firma del produttore.

I file vengono preparati in `%LOCALAPPDATA%\AssistenteIT\Updates`. L’installazione attende la chiusura di hub, launcher e altri moduli senza terminarli; usa il setup per utente e mantiene il percorso registrato, configurazione e DPAPI. A successo riapre il launcher. Se i moduli restano aperti o l’installer segnala un errore, l’aggiornamento viene annullato e resta disponibile il setup manuale. Nella versione eseguita dal checkout, usare l’installer prima di attivare l’OTA.

### Primo accesso Graph dalla finestra

Dalla versione 1.0.10 Connect-ExplorerGraph usa il login interattivo Microsoft/WAM del vecchio script e la cache protetta `CurrentUser` del modulo Microsoft. La suite fornisce una finestra Windows valida al broker, anche se viene avviata senza console. La finestra di attesa compare prima della chiamata; se Microsoft usa il codice dispositivo, le istruzioni restano visibili e copiabili, anche se arrivano dalla console nascosta. Annullare la finestra interrompe la ricerca. Le sessioni valide e gli ambiti esistenti vengono riutilizzati. Il programma non concede consensi né modifica i criteri del tenant.

### Computer AD con oggetti figli

Un computer AD può contenere informazioni di recupero BitLocker (`msFVE-RecoveryInformation`) o altri oggetti figli. L’anteprima di eliminazione elenca classe, GUID e percorso di ogni figlio sui DC selezionati, senza leggere password o chiavi di recupero. Quando sono presenti figli, occorre spuntare la conferma dedicata prima di **Elimina definitivamente**: anche le informazioni di recupero BitLocker elencate verranno eliminate da AD.

Il modulo richiede `-IncludeAdChildren` per applicare un piano con figli. La conferma vale solo per gli ID nell’anteprima. Prima della prima scrittura rilegge computer, discendenti e singoli GUID; oggetti nuovi o spostati, protezioni dall’eliminazione accidentale ed errori di lettura bloccano quel computer. I figli già assenti sono tollerati. Le stesse verifiche vengono ripetute durante l’esecuzione: rimane possibile un cambiamento concorrente dopo un controllo, che può lasciare un’operazione parziale, riportata negli esiti.

La rimozione elimina per GUID solo i figli confermati, dai più profondi ai genitori, quindi usa `Remove-ADComputer` sul computer. Non usa `Remove-ADObject -Recursive` e non modifica le protezioni dall’eliminazione accidentale. Ogni figlio ha una riga negli esiti; un errore blocca il computer e le origini successive. Nessuna eliminazione viene eseguita sui dispositivi aziendali durante i test: i casi AD sono simulati.
