# Assistente IT

La suite raccoglie gli strumenti IT in un unico punto di avvio. Il primo modulo è **Computer Explorer**, per AD, Entra ID, Intune e GLPI. I moduli vengono registrati in `assistente-it.json` e avviati in processi Windows PowerShell separati.

## Installazione per i colleghi

1. Accedere a GitHub con un account autorizzato al repository privato [RC_OPBG_4](https://github.com/minirusty97/RC_OPBG_4).
2. Aprire [Releases](https://github.com/minirusty97/RC_OPBG_4/releases/latest).
3. Scaricare **Assistente-IT-Setup-VERSIONE.exe** negli asset della release. Gli archivi automatici Source code contengono i sorgenti.
4. Eseguire il setup con il proprio utente e avviare **Assistente IT** dal menu Start o dal desktop.
5. Aprire **Impostazioni**, verificare i DC, inserire l'URL API GLPI corretto e, se si usa GLPI, il proprio User token e l'App token.
6. Aprire Computer Explorer. Il login Graph usa l'account del collega e i suoi permessi effettivi.

L'installer è per utente, a 64 bit. Il programma viene installato normalmente in `%LOCALAPPDATA%\Programs\AssistenteIT`; non richiede l'elevazione per installare la suite. Il modulo Microsoft.Graph.Authentication è incluso, nella versione fissata in `assistente-it.json`, e non deve essere installato dai colleghi.

Per le operazioni AD serve **RSAT / ActiveDirectory**, da installare o abilitare sul PC con i necessari diritti amministrativi. La pagina iniziale ne segnala la presenza. Servono inoltre Windows PowerShell 5.1, accesso alla rete aziendale e i permessi appropriati nelle fonti consultate. I permessi amministrativi locali non sostituiscono le autorizzazioni AD, Entra o Intune.

Il launcher avvia Windows PowerShell con `-NoProfile -STA` e una ExecutionPolicy Bypass limitata al processo. Non modifica le impostazioni persistenti; le policy di gruppo mantengono la loro precedenza. Il setup e il launcher di questa prima versione non sono firmati con un certificato di code signing; la release include il checksum SHA256.

## Configurazione personale e aggiornamenti

I dati personali sono separati dai file del programma:

| Percorso | Contenuto |
| --- | --- |
| `%LOCALAPPDATA%\AssistenteIT\Config\computer-explorer.config.local.json` | DC, URL GLPI e opzioni di ricerca |
| `%LOCALAPPDATA%\AssistenteIT\Config\glpi-credentials.dpapi.json` | Token GLPI cifrati per l’account Windows |
| `%LOCALAPPDATA%\AssistenteIT\Config\.env` | Importazione dei token delle vecchie versioni; ripulito dopo verifica |

La prima apertura copia i modelli solo se i file personali non esistono. In Impostazioni i campi dei token sono vuoti: lasciarli vuoti conserva i token già salvati. I token vengono salvati cifrati con DPAPI per l’account Windows corrente; non vengono incorporati nella build, pubblicati nella release o condivisi fra utenti.

Per aggiornare, chiudere la suite e i moduli aperti, scaricare il nuovo setup dalla release ed eseguirlo. Configurazione e token vengono conservati. Il setup rifiuta di aggiornare mentre un processo della suite è aperto e impedisce di installare una versione precedente. La disinstallazione rimuove il programma e mantiene i dati personali; questi possono essere rimossi separatamente dalla propria cartella dati.

Dalla 1.0.8, **Aggiornamenti** controlla il feed pubblico e **Aggiorna** scarica e installa su richiesta. Il controllo parte anche all’apertura della finestra, in background. La repository deve essere pubblica; i client non memorizzano token GitHub. La prima versione dotata di OTA va installata manualmente. I moduli aperti devono essere chiusi prima dell’installazione e non vengono terminati automaticamente.

Dalla versione **1.0.2** anche cartelle, chiave di disinstallazione, script di avvio e nomi interni usano **Assistente IT**. Il setup riconosce le installazioni 1.0.0 e 1.0.1, sposta i dati personali nel nuovo percorso e rimuove la precedente registrazione e i file del programma. Una precedente installazione in una cartella personalizzata viene trasferita al nuovo percorso predefinito; per mantenerla, selezionare esplicitamente quella stessa cartella nel setup.

Se esistono già dati nel nuovo percorso, i file correnti vengono conservati e vengono importati solo quelli mancanti. La copia completa dei dati precedenti rimane in `AssistenteIT\Importazione-precedente`, in una sottocartella distinta. I file estranei all'applicazione nella vecchia cartella di installazione vengono conservati. Il vecchio nome compare nei sorgenti solo per riconoscere le installazioni precedenti, nelle prove di aggiornamento e nelle note storiche; il dominio AD e l'indirizzo del repository sono indipendenti dal nome del programma.

## Riutilizzare i file della versione da sorgenti

Aprire e chiudere una volta la suite per creare la cartella personale. Chiudere i moduli, poi copiare il proprio `computer-explorer.config.local.json` e il proprio `.env` dalla cartella Git alla cartella `Config` indicata sopra, sostituendo soltanto i modelli appena creati. È anche possibile impostare tutto dalla finestra Impostazioni.

L'avvio diretto `Start-ComputerExplorer.ps1` rimane disponibile e continua a usare, per impostazione predefinita, i file accanto allo script. La suite passa invece esplicitamente `-ConfigPath` e `-EnvPath` con i percorsi personali.

## Versioni, build e release

Il workflow **PowerShell checks and installer** esegue:

1. Parser e suite di test su Windows PowerShell 5.1, con dati sintetici e API simulate.
2. Compilazione di un piccolo launcher C# e creazione del setup con NSIS 3.13.0.
3. Installazione delle release originali 1.0.0 e 1.0.1, scaricate da GitHub e verificate tramite SHA256; aggiornamento da cartella predefinita e personalizzata, anche nella stessa cartella; migrazione e confronto SHA256 dei file personali, rimozione della vecchia registrazione, avvio della finestra e verifica dei collegamenti, reinstallazione, blocco con programma aperto e con una versione più recente registrata, disinstallazione e installazione pulita.
4. Pubblicazione dell'installer e del checksum come artifact del workflow.
5. Su push a `main`, pubblicazione della release `vVERSIONE`, se non esiste già. La bozza viene pubblicata solo dopo il caricamento degli asset.

Per rilasciare un aggiornamento:

1. Creare un branch `feature/...` a partire da `main`.
2. Modificare i sorgenti e incrementare **Version** in `assistente-it.json`, per esempio da `1.0.2` a `1.0.3`.
3. Aggiungere le note in `docs/releases/1.0.3.md`.
4. Aprire una pull request verso `main` e attendere i controlli verdi.
5. Unire la pull request. La build su `main` genera e pubblica automaticamente la nuova release.

Ogni merge viene verificato e produce un artifact. Una versione già pubblicata non viene sostituita: per distribuire un nuovo installer va incrementata la versione. Il tag identifica il commit sorgente; `app/build-info.json` nell'installazione riporta commit, versione e versione Graph. La build usa una lista esplicita dei file runtime e non copia ricorsivamente il checkout: file personali, test e vecchio tool di rimozione restano esclusi dal setup.

Le prove del workflow non si collegano ai DC o ai tenant aziendali. La prima distribuzione va provata su un PC di un collega per confermare rete, login e permessi effettivi.

## Build locale

Su Windows PowerShell a 64 bit, con NSIS installato:

```powershell
choco install nsis --version=3.13.0 --yes
.\build\Build-AssistenteIT.ps1
```

Il setup e il checksum vengono scritti in `output\assistente-it`. La prima build scarica da PowerShell Gallery la versione Graph fissata; le successive riusano la cache locale. `-MakeNsisPath` permette di indicare un compilatore NSIS in un altro percorso.

`build/Test-Installer.ps1` è riservato a un runner Windows isolato: rifiuta di operare se esistono già un'installazione o dati personali della suite. Il test riceve i setup originali 1.0.0 e 1.0.1 per verificare la migrazione durante aggiornamenti reali.

## Aggiungere moduli

Registrare un nuovo modulo nell'array `Modules` di `assistente-it.json`, con ID univoco, nome, descrizione e percorso relativo dello script di avvio. Lo script deve essere incluso nella lista runtime di `build/Build-AssistenteIT.ps1`, insieme alle sue dipendenze. Non basta registrare il nome nel menu: il manifest controlla anche che il percorso esista e rimanga dentro la cartella applicativa.

Con `UsesAppSettings: true` il modulo riceve i parametri `ConfigPath` ed `EnvPath`; con `false` viene avviato senza questi parametri. La finestra iniziale costruisce automaticamente il relativo pulsante. Ogni modulo conserva la propria sessione, mentre installer, versione e impostazioni restano comuni.

## Riferimenti

- [NSIS: manuale](https://nsis.sourceforge.io/Docs/), [licenza](https://nsis.sourceforge.io/Docs/AppendixI.html) e [opzioni del setup](https://nsis.sourceforge.io/Docs/Chapter3.html).
- [Microsoft.Graph.Authentication 2.41.1](https://www.powershellgallery.com/packages/Microsoft.Graph.Authentication/2.41.1).
- [GitHub: gestione delle release](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

### Credenziali GLPI cifrate (dalla 1.0.6)

I token vengono salvati in `glpi-credentials.dpapi.json`, accanto al `.env` configurato (nell’installazione: `%LOCALAPPDATA%\AssistenteIT\Config`). Windows DPAPI CurrentUser li protegge senza una chiave condivisa nell’app. Il salvataggio richiede Windows; su altri sistemi non viene usato un formato in chiaro.

Alla prima ricerca GLPI o al salvataggio delle impostazioni, i token presenti nel `.env` in uso vengono importati, scritti e riletti per verifica prima di rimuovere le sole righe GLPI_USER_TOKEN/GLPI_APP_TOKEN. Gli altri contenuti rimangono. Se la scrittura o la verifica falliscono, il testo originale non viene ripulito. Se archivio e .env contengono token discordanti, reinserire entrambi dalle impostazioni; un archivio illeggibile va conservato per il recupero e rimosso dal percorso attivo prima di reinserire le credenziali.

Le caselle vuote nelle impostazioni conservano i token esistenti; Token GLPI in Computer Explorer salva ora le nuove credenziali cifrate. Ogni collega configura i propri token, evitando di copiare questo archivio su un altro account o PC. L’archivio resta fuori da Git e dal pacchetto di installazione.

La migrazione interessa solo il .env del percorso attivo. Copie precedenti nel checkout, backup e Importazione-precedente non vengono eliminate automaticamente. La rimozione del testo non è una cancellazione sicura dei supporti: se i token sono stati esposti, revocarli e generarne di nuovi. DPAPI protegge il salvataggio su disco; l’app deve poterli usare durante le richieste API e non protegge da codice eseguito con il medesimo account.

## Accesso Microsoft Graph dalla versione 1.0.10

Assistente IT usa Windows PowerShell 5.1 a 64 bit e il modulo Graph incluso nell’installer. Il login usa il flusso interattivo Microsoft/WAM e la cache `CurrentUser` gestita dal modulo Microsoft, così la sessione può essere riutilizzata alle aperture successive. I criteri del tenant possono comunque richiedere una nuova autenticazione.

Consenso amministrativo e autenticazione sono distinti: cambiare versione di PowerShell non concede permessi. Il programma mantiene la stessa app Graph predefinita e gli stessi permessi del vecchio script. Se compare “approvazione amministratore richiesta”, verificare account, tenant, app e permessi mostrati nella pagina Microsoft.
