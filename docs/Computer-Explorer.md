# Computer Explorer — console di ricerca

Aggiornamento: 30 ottobre 2026. Versione funzionale integrata in `main`.

## Fase attuale

`Start-ComputerExplorer.ps1` è la prima interfaccia Windows Forms per la ricerca aggregata AD / Entra ID / Intune / GLPI. `ComputerExplorer.Core.psm1` gestisce letture, raccolte cloud, cache e aggregazione. `ComputerExplorer.Parallel.psm1` coordina un lettore AD sequenziale dedicato e tre lettori indipendenti per Entra, Intune e GLPI. Riutilizza `Test-AdLookup.ps1 -PassThru` per AD e `GLPI.Inventory.psm1` per GLPI.

La console permette la rimozione delle righe selezionate da AD, Entra e Intune tramite `ComputerExplorer.Removal.psm1`. GLPI resta in consultazione. Il tool precedente `Remove-Computer-FullTool.ps1` rimane disponibile.

## Ricerca e associazioni

- Il frammento viene cercato senza distinguere maiuscole e minuscole. Su AD si cercano Name, DNSHostName e sAMAccountName tramite filtro LDAP letterale; nel cloud e in GLPI si cerca il nome del dispositivo.
- I candidati sono l'unione delle quattro fonti. Ogni nome completo ha una riga; nomi simili restano separati. Si ignorano soltanto maiuscole e spazi esterni.
- Le registrazioni duplicate dello stesso nome vengono contate per ID distinti. Tutti gli oggetti restano disponibili nel dettaglio: AD ObjectGUID e DN, Entra ObjectId e DeviceId, Intune managedDeviceId e azureADDeviceId, GLPI ID Computer.
- Suffissi GLPI fra parentesi non vengono rimossi: una corrispondenza ipotizzata non deve unire asset diversi.
- La griglia segnala GUID o percorsi AD diversi, seriali diversi e DeviceId Intune che non compare tra le registrazioni Entra dello stesso nome. Queste segnalazioni richiedono verifica; non sono associazioni operative automatiche.

## Colonne e colori

| Colonna | Verde | Giallo | Rosso | Grigio |
|---|---|---|---|---|
| AD | Presente su tutti i DC configurati, normalmente 5/5 | Presente su alcuni DC, tutti verificati | Assente, tutti verificati | DC non verificabile o fonte esclusa/in attesa |
| Entra ID | Una registrazione | Più registrazioni dello stesso nome | Zero, lettura completata | Errore, esclusa o in attesa |
| Intune | Una registrazione Windows | Più registrazioni Windows | Zero, lettura completata | Errore, esclusa o in attesa |
| GLPI | Un Computer visibile | Più Computer dello stesso nome | Zero nel contesto consultato, lettura completata | Errore, esclusa o in attesa |

Accanto a ciascuna fonte compare la sua data: ultima modifica AD (`Modified`), attività Entra (`approximateLastSignInDateTime`), check-in Intune (`lastSyncDateTime`) e ultimo inventario GLPI (`last_inventory_update`). La modifica della scheda GLPI (`date_mod`) resta un campo separato nel dettaglio. Le date sono valori DateTime ordinabili, formattati `dd/MM/yyyy HH:mm`; per più oggetti/DC si usa il massimo delle date valide mantenendo tutti i valori individuali nel dettaglio. Date mancanti, non valide e segnaposto compaiono come —. Graph viene convertito nell’ora locale del PC; GLPI senza offset conserva l’orario del server. `whenChanged` non è replicato: il massimo AD rappresenta la modifica più recente osservata sui DC letti.

Il numero dei DC verificati è nel dettaglio e nel tooltip della cella AD, senza una colonna dedicata. Le altre colonne riportano stato GLPI, percorso AD e segnalazioni. Stato GLPI conserva le etichette reali: la presenza verde può coincidere con uno stato Dismesso. Conteggi e testo affiancano sempre il colore.

Il percorso viene da CanonicalName; il DN originale rimane nel dettaglio. Un DC in errore non viene interpretato come assente. Le risposte valide degli altri DC vengono conservate con colore grigio per la verifica complessiva incompleta.

## Finestra e autenticazione

La griglia mostra i risultati; il pannello inferiore espone gli oggetti del nome selezionato e una scheda con esiti delle fonti, errori, orari e cache. Le caselle permettono di escludere una fonte e Interrompi annulla il coordinatore e tutti i lettori della ricerca. La finestra riceve gli aggiornamenti tramite una coda concorrente: i controlli WinForms restano sul thread della UI.

I token GLPI sono salvati con Windows DPAPI CurrentUser tramite il lettore condiviso Glpi.Credentials.ps1, usato dalla suite, dalla finestra e da Test-GlpiLookup.ps1. Il .env precedente viene migrato alla prima lettura; le sole righe dei token vengono rimosse dopo verifica dell’archivio cifrato. I token restano SecureString nella sessione della finestra. Il pulsante Token GLPI li aggiorna e li salva cifrati. Il JSON contiene soltanto configurazione e URL, non credenziali.

Graph usa Microsoft.Graph.Authentication e l'endpoint Global graph.microsoft.com. **Accesso utente (app Microsoft)** mantiene il flusso interattivo precedente e gli ambiti del tool, riutilizzando tenant, client e ambiti correnti quando disponibili. Da 1.0.18 il wrapper esegue accesso e verifica prima di aprire il modulo. **Accesso delegato (app dedicata)** usa Tenant ID, Client ID e `.default` per leggere gli ambiti gia concessi; le funzioni del modulo non richiedono consensi aggiuntivi. I diritti effettivi dipendono dai ruoli Entra/Intune dell'utente. La modalita applicativa con certificato e stata rimossa. Vedere la [guida per il sistemista all'accesso delegato](Autenticazione-Graph-Delegata.md).

## Raccolte e cache

- AD: lettura dei DC configurati ad ogni ricerca, caratteri LDAP escaped e risultati validati separatamente per ciascun DC.
- Entra: GET v1.0/devices con selezione dei campi necessari e raccolta di tutte le pagine. Filtro locale contains, per trovare anche frammenti in mezzo al nome.
- Intune: GET v1.0/deviceManagement/managedDevices, raccolta paginata, record Windows e filtro locale contains. managedDeviceId e azureADDeviceId restano campi distinti.
- GLPI: API V1, ricerca Computer paginata, ID ricavati dalle opzioni di ricerca e denominazioni reali degli stati. Si legge una scheda per risultato e si riusano gli stati nel corso della singola ricerca; grandi elenchi possono essere più lenti.

La cache cloud completa è una hashtable sincronizzata condivisa dai lettori, conservata dal coordinatore nel runspace persistente e invalidata dalle rimozioni. CloudCacheMinutes vale 5 nel modello, accetta 0–60 e con 0 disabilita il riuso. La chiave include tenant, client, account, tipo di autenticazione, ambiente, ambiti e fonte. Rileggi cloud forza il refresh; orario originale e provenienza cache sono visibili. Una lettura fallita invalida la relativa voce e produce Non verificabile, senza inventario parziale o successo ripreso dalla cache.

I nextLink vengono verificati per host e risorsa. Pagine ripetute, ID non validi e nomi discordanti per lo stesso ID producono errore. I record cloud sono pubblicati soltanto al termine della raccolta. Gli aggiornamenti della griglia arrivano dopo ogni fonte, non dopo ogni singolo dispositivo.

GLPI usa il contesto predefinito dell'utente API. La selezione esplicita di profilo/entità e l'apertura della scheda web sono da progettare.

## Prove effettuate e limiti

- Parser PowerShell e 65 casi automatici in PowerShell 7.4.19: 28 cloud/aggregazione/date/worker, 12 AD, 18 GLPI e 7 per le credenziali `.env`. La suite cloud/date passa anche con fuso Europe/Rome. Dati sintetici, senza connessioni al tenant o ai DC aziendali. Inclusi runspace, coda concorrente, annullamento e riuso del worker.
- GLPI aziendale, 13 ottobre 2026: 528 record con ID validi e distinti, 527 nomi distinti e cinque stati. Il nome duplicato ha due seriali differenti. I risultati della prova appartengono all'entità 0; non descrivono l'intero server.
- AD aziendale, stessa data: nel campione di 14 righe inviato dall'utente, 5/5 presenti e verificati, percorsi valorizzati e nessun GUID discordante. Le righe non condivise non sono state esaminate.
- Il 15 ottobre 2026 l’utente ha confermato il funzionamento della prima finestra. Le nuove colonne sono verificate con risposte simulate; i nuovi valori reali e la loro visualizzazione vanno verificati sul PC aziendale.

Comandi di avvio e test: vedere [README](../README.md).

## Passi successivi

1. Verificare sul PC aziendale le quattro date aggiunte accanto alle presenze.
2. Rifinire tempi, colonne e regole di associazione usando i casi reali e concordare profili/entità GLPI.
3. Rifinire il flusso di rimozione dopo la prova controllata nell'ambiente aziendale.

Ordine previsto per la rimozione: Intune, AD, Entra. GLPI rimane una fonte di consultazione. La cancellazione di una registrazione Windows da Intune avvia anche il ritiro dalla gestione, come già indicato nel tool esistente.

## Riferimenti tecnici

- [GLPI REST API V1](https://help.glpi-project.org/documentation/modules/configuration/general/api/api)
- [Graph: list devices](https://learn.microsoft.com/en-us/graph/api/device-list?view=graph-rest-1.0)
- [Graph: list managedDevices](https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-list?view=graph-rest-1.0)
- [Autenticazione Graph PowerShell](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands?view=graph-powershell-1.0)
- [AD: Get-ADComputer](https://learn.microsoft.com/en-us/powershell/module/activedirectory/get-adcomputer?view=windowsserver2025-ps)

Campi data verificati sulle fonti ufficiali:

- [GLPI 10.0.11 Computer: last_inventory_update](https://github.com/glpi-project/glpi/blob/10.0.11/src/Computer.php)
- [AD whenChanged](https://learn.microsoft.com/en-us/windows/win32/adschema/a-whenchanged)

## Rimozione dalla griglia

La legenda superiore è rimossa. Le colonne AD, Modifica AD, Entra ID, Attività Entra, Intune, Check-in Intune, GLPI e Inventario GLPI vengono dimensionate sui valori formattati e sulle intestazioni. I contatori **Risultati** e **Selezionati** sono sempre visibili.

Selezionare una o più righe con Ctrl+clic o Maiusc+clic, quindi premere **Elimina...**. La finestra delle origini propone **AD, Entra e Intune già spuntati**; si possono deselezionare le origini da mantenere. GLPI non è selezionabile per la rimozione.

**Verifica oggetti** rilegge i nomi completi senza usare la cache, verifica tutti i DC selezionati e mostra gli ID esatti nell'anteprima. Solo **Elimina definitivamente** avvia la rimozione. La cancellazione di una registrazione Windows in Intune avvia anche il ritiro dalla gestione.

Il piano vale cinque minuti, viene consumato una sola volta ed è legato alla sessione Graph. Gli ID, i nomi e gli altri dati di identità vengono ricontrollati prima delle scritture e immediatamente prima di ogni eliminazione. Oggetti nuovi o modificati dopo l'anteprima bloccano quel computer. Le duplicazioni dello stesso nome sono mostrate e incluse nell'anteprima; nomi soltanto simili e altre piattaforme Intune sono esclusi.

L'ordine è **Intune → AD sui DC → Entra**. Un errore blocca le operazioni successive per quel computer; gli altri computer proseguono. Le assenze già confermate, anche dovute alla replica AD, sono indicate come **Già assente**. Gli esiti per oggetto sono nella scheda **Esiti eliminazione**. Dopo il completamento la ricerca viene aggiornata con rilettura cloud.

**Interrompi** durante una cancellazione termina il computer corrente e salta quelli successivi. Dopo un'interruzione o un errore generale, eseguire una nuova ricerca prima di un'altra eliminazione. La chiusura normale della finestra attende lo stesso arresto.

Il modulo `ComputerExplorer.Removal.psm1` espone preparazione e applicazione del piano. Supporta `-WhatIf` per eseguire le verifiche senza cancellare.


Il workflow `.github/workflows/powershell-checks.yml` esegue parser e test su Windows. Le nuove prove coprono ordine di rimozione, ID separati, preflight completo, nuove identità, cambi di nome/seriale, 404, replica AD, errori isolati per computer, origini escluse, WhatIf, piani scaduti o riusati, annullamento e integrità del piano. Lo smoke test costruisce i controlli WinForms, senza collegarsi alle fonti aziendali.

## Esecuzione parallela delle ricerche

La finestra richiama Invoke-ComputerExplorerParallelSearch. GLPI e i lettori dei singoli DC partono indipendentemente. Un solo lavoro verifica con Connect-ExplorerGraph la sessione gia predisposta dal wrapper, senza autenticarsi; al termine partono Entra e Intune contemporaneamente, riutilizzando la sessione statica del Graph SDK nello stesso processo. Nessun lettore cloud esegue un proprio login.

AD usa un pool STA con un solo runspace e una coda: il DC successivo parte soltanto dopo il termine del precedente, anche in caso di errore. Un secondo pool STA con al massimo tre lettori mantiene Entra, Intune e GLPI in parallelo, indipendenti da AD. Ogni lettore AD usa il parametro DomainController di Test-AdLookup.ps1, limitato ai DC configurati. Gli esiti AD vengono riuniti per DC; la presenza rimane grigia finché tutti i DC non hanno terminato o se una verifica fallisce.

I risultati vengono pubblicati progressivamente. Le fonti ancora in attesa restano grigie; un errore Graph non ferma AD o GLPI. La UI riunisce gli aggiornamenti ravvicinati e abilita la rimozione solo dopo la fine della ricerca. Le cancellazioni conservano il piano e l'ordine sequenziale già implementati.

Alla chiusura del lavoro la finestra applica anche il risultato finale restituito dal coordinatore. Questo evita che una ricerca terminata durante il ridisegno della griglia rimanga visualizzata come «in corso» con Elimina disabilitato. Le prove di completamento usano pipeline asincrone reali e forzano questa sovrapposizione; ricerche ancora in esecuzione, fallite o interrotte mantengono la rimozione disabilitata.

Ogni API mantiene la propria paginazione sequenziale. Il connettore GLPI mantiene una sola sessione e la lettura ordinata delle schede; il suo tempo può dominare ricerche con molti risultati. Il parallelismo riduce le attese fra sorgenti, senza promettere un rapporto fisso di accelerazione.

L'annullamento invia lo stop a tutti i lavori, ne attende la chiusura e dispone il pool. Le cache parziali non vengono pubblicate; le cache complete restano condivise e il refresh forzato viene rispettato.

Riferimenti: [runspace pool PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/developer/hosting/creating-multiple-runspaces) e [GraphSession thread-safe del Graph SDK](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/main/src/Authentication/Authentication.Core/Common/GraphSession.cs).

## Stato delle fonti e completamento

Il footer mostra separatamente AD, Entra ID, Intune e GLPI. Verde indica un esito corretto anche senza risultati, rosso un esito con errori, giallo una lettura ancora in corso e grigio una fonte esclusa. Per AD si vede il numero di DC completati; il suggerimento mostra il DC attualmente interrogato e gli eventuali errori.

Il completamento globale richiede la conclusione di tutti i lettori. Un errore di una fonte non lascia la ricerca appesa e non interrompe le fonti indipendenti. Le righe restano consultabili durante la ricerca; le operazioni sui risultati selezionati vengono abilitate solo dopo la conclusione globale e la pulizia dei lettori. L’annullamento conserva lo stato incompleto e non autorizza la cancellazione.

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

### Computer AD con oggetti figli

Un computer AD può contenere informazioni di recupero BitLocker (`msFVE-RecoveryInformation`) o altri oggetti figli. L’anteprima di eliminazione elenca classe, GUID e percorso di ogni figlio sui DC selezionati, senza leggere password o chiavi di recupero. Quando sono presenti figli, occorre spuntare la conferma dedicata prima di **Elimina definitivamente**: anche le informazioni di recupero BitLocker elencate verranno eliminate da AD.

Il modulo richiede `-IncludeAdChildren` per applicare un piano con figli. La conferma vale solo per gli ID nell’anteprima. Prima della prima scrittura rilegge computer, discendenti e singoli GUID; oggetti nuovi o spostati, protezioni dall’eliminazione accidentale ed errori di lettura bloccano quel computer. I figli già assenti sono tollerati. Le stesse verifiche vengono ripetute durante l’esecuzione: rimane possibile un cambiamento concorrente dopo un controllo, che può lasciare un’operazione parziale, riportata negli esiti.

La rimozione elimina per GUID solo i figli confermati, dai più profondi ai genitori, quindi usa `Remove-ADComputer` sul computer. Non usa `Remove-ADObject -Recursive` e non modifica le protezioni dall’eliminazione accidentale. Ogni figlio ha una riga negli esiti; un errore blocca il computer e le origini successive. Nessuna eliminazione viene eseguita sui dispositivi aziendali durante i test: i casi AD sono simulati.

### Archivio BitLocker nelle Note native GLPI

La versione 1.0.13 salva le password di recupero **in chiaro nelle Note native** della scheda computer GLPI, senza Fields, Accounts o altri plugin e senza modifiche allo schema di GLPI 10.0.11. Non richiede una password aggiuntiva per l'archivio. La visibilita dipende dai diritti GLPI di lettura delle Note; il profilo del token deve poter leggere e aggiornare le Note (READNOTE e UPDATENOTE). Usare l'URL diretto di apirest.php; l'archiviatore non segue reindirizzamenti. HTTPS protegge token e contenuti durante il trasporto.

**Rispetta le note esistenti:** il codice puo solo leggere e creare Note tramite GET/POST, senza PUT, PATCH o DELETE. Crea una nuova nota per ogni Recovery Key ID da archiviare. Le Note precedenti, anche scritte manualmente, non vengono modificate o cancellate. Le note create dall'app hanno un marcatore di formato e contengono Computer ID GLPI, nome, seriale, Key ID, password di recupero, volume, origine e data di acquisizione. Una chiave identica gia archiviata dall'app viene riletta e riutilizzata; un valore discordante blocca l'operazione senza sovrascrivere nulla. Un salvataggio parziale rimane disponibile e viene riutilizzato al tentativo successivo.

**Archivia BitLocker** esegue il backup senza cancellare registrazioni. **Leggi archivio** mostra le chiavi anche dopo la cancellazione AD/Entra e permette la copia. **Elimina** salva prima le chiavi nelle Note GLPI e le rilegge. Da 1.0.21, se manca una scheda GLPI univoca, si puo proseguire soltanto dopo la conferma separata del rischio di perdita, con download e stampa facoltativi. Gli altri errori bloccano il computer prima di eliminare. Conservare la scheda GLPI e i backup di GLPI: la cancellazione permanente della scheda o delle Note puo eliminare l'archivio.

Vengono raccolte tutte le chiavi/versioni disponibili nelle origini selezionate. Repliche AD e copie AD/Entra identiche sono deduplicate per Key ID. Per il cloud vengono usati gli Entra deviceId, non gli object ID Entra o i managedDeviceId Intune. Occorrono BitlockerKey.Read.All e un ruolo adeguato; la lettura genera gli audit Microsoft previsti. In AD occorre poter leggere gli attributi msFVE. Gli errori non vengono interpretati come assenza di chiavi. I messaggi di avanzamento riportano soltanto metadati e conteggi.

L'archiviazione richiede una sola scheda GLPI attiva con un seriale significativo. Da 1.0.21 viene cercata per seriale Intune quando disponibile, anche se il nome e diverso; in assenza di un seriale valido si cerca il nome esatto. Quando il confronto hardware non e completo, per esempio con sola AD o vecchie identita Entra senza riscontro Intune, l'anteprima richiede una conferma esplicita del collegamento alla scheda. Il backend applica lo stesso vincolo: il nome non certifica l'identita hardware AD.

Prima della prima scrittura vengono ricontrollati identita, scheda GLPI e chiavi. Prima di ogni eliminazione viene ricontrollato che le chiavi dell'origine siano coperte dal backup verificato. Le API non offrono una transazione distribuita: cambiamenti concorrenti dopo l'ultima lettura possono causare un'operazione parziale, riportata negli esiti.

I test usano AD, Graph e GLPI simulati e la GUI reale su Windows. Non vengono lette chiavi aziendali nei test. La prima prova su GLPI reale va fatta tramite **Archivia BitLocker**, controllando la nuova nota e l'integrita di quelle precedenti, prima di usare l'eliminazione.

### Attese cloud e nomi assenti (1.0.14)

Una ricerca senza corrispondenze termina con zero risultati e il messaggio **Nessun dispositivo trovato** quando tutte le fonti selezionate hanno risposto correttamente. Il nome non viene cercato nel cestino Entra: la ricerca riguarda le registrazioni attive.

Il footer Entra/Intune mostra la pagina in lettura e il numero di record gia letti. `Search.CloudReadTimeoutSeconds` limita ogni lettore cloud a **90 secondi** per impostazione predefinita; accetta 1–600 e viene applicato anche ai JSON locali che non contengono ancora la voce. Il conteggio parte dopo l'autenticazione Graph, all'avvio del lettore. Il limite riguarda la ricerca nella finestra, non la preparazione o l'esecuzione delle eliminazioni.

Al limite il coordinatore richiede l'arresto del lettore, ne attende la chiusura e conclude la fonte con un errore esplicito. La fonte resta non verificabile, senza essere interpretata come dispositivo assente; i risultati delle altre fonti restano disponibili. La relativa cache viene invalidata e una nuova ricerca puo essere eseguita con **Rileggi cloud**. Nessun inventario parziale viene pubblicato come completo.

L'inventario completo e il filtro locale sul frammento restano necessari per mantenere le corrispondenze in mezzo al nome. Lo screenshot con Entra in attesa non consente da solo di distinguere una pagina lenta, un retry Graph o un problema di rete: avanzamento e timeout rendono il caso riconoscibile senza lasciare un'attesa senza limite.

### Ricerca diretta delle chiavi BitLocker

**Cerca chiavi** consulta prima **Intune** usando il nome esatto del PC o la riga selezionata. Ricava `azureADDeviceId` dal dispositivo gestito e legge le chiavi BitLocker cloud associate: non usa il managedDeviceId come Device ID e non attende l'inventario completo Entra. Le chiavi visibili in Intune sono conservate in Entra ID; restano necessari consenso `BitlockerKey.Read.All` e un ruolo adeguato. La funzione puo essere avviata anche con zero righe nella griglia, inserendo il nome esatto, e non richiede token GLPI.

Se Intune non restituisce chiavi, anche per un problema di accesso, passa ad **AD** nell'ordine dei DC configurati e si ferma al primo DC che recupera chiavi. La finestra riporta separatamente gli esiti: un errore cloud non viene presentato come assenza di chiavi. La consultazione AD funziona anche sui computer protetti dall'eliminazione accidentale, dato che non li modifica. Le letture hanno un limite di attesa e possono essere interrotte.

La finestra mostra le chiavi leggibili, l'origine, il seriale Intune disponibile e il Key ID, e permette la copia. Non archivia e non elimina nulla. **Leggi archivio** continua a consultare soltanto le Note GLPI gia salvate, utile dopo la cancellazione delle registrazioni.

Anche il backup prima dell'eliminazione legge ora il cloud prima delle password AD e gestisce le risposte Graph dirette o contenute in `value`. Il backup conserva la verifica completa di tutte le origini selezionate: un errore su una di esse continua a bloccare l'eliminazione; il fallback della consultazione non aggira questo controllo. Le Note GLPI preesistenti restano inalterate.

### Accesso delegato con app dedicata (1.0.17)

**Accesso delegato (app dedicata)** richiede Tenant ID e Client ID, senza certificato. Ogni tecnico accede con il proprio account; assegnazioni e ruoli determinano accesso e operazioni consentite. La sessione deve corrispondere a identita delegata, app e tenant configurati. Il riepilogo iniziale segnala gli ambiti disponibili; le funzioni non richiedono nuovi consensi. Il programma non riprova con un'identita applicativa in caso di errore. Configurazione e limiti dei ruoli sono descritti nella [guida per il sistemista](Autenticazione-Graph-Delegata.md).

### Accesso iniziale comune (1.0.18)

**Accesso e apri** esegue login e verifica dei permessi nel wrapper, prima della finestra del modulo. L'app dedicata usa i consensi gia concessi con `.default` e mostra subito le funzioni disponibili. Ricerca, BitLocker ed eliminazioni non avviano richieste aggiuntive di consenso. La cancellazione Entra resta supportata con l'ambito necessario; una sua assenza e segnalata all'inizio senza un accesso alternativo automatico. La modalita con certificato e stata rimossa. [Flusso e configurazione dei moduli futuri](Accesso-Iniziale.md).

### Accesso separato e modalita dei moduli (1.0.19)

Premere **Accesso** nella barra inferiore: la verifica abilita le schede autorizzate, senza aprire moduli. **Apri modulo** riutilizza la sessione gia verificata. I requisiti di lettura e scrittura sono separati; per i moduli futuri si possono dichiarare gruppi Entra distinti per i colleghi. Sono stati ripristinati gli stili Windows e l'identita applicazione con icona propria. Il controllo si chiama **Cerca aggiornamenti**; il messaggio senza nuove versioni e **Assistente IT è aggiornato**. [Configurazione e comportamento](Accesso-Iniziale.md).


## Ricerca GLPI per seriale e conferma senza archivio (1.0.21)

Quando Intune fornisce un seriale hardware valido, GLPI viene interrogato per quel seriale e l'asset e associato al PC anche se il nome GLPI e diverso. Il nome GLPI originale resta visibile nei dettagli. Le schede omonime con seriale diverso non sono associate al PC Intune; senza seriale valido si conserva la ricerca per nome. I seriali generici del firmware non sono usati come identita. La ricerca per seriale usa il campo scoperto nelle opzioni GLPI, controlli esatti sul dettaglio e criteri suddivisi in lotti nella stessa sessione.

La ricerca iniziale delle quattro fonti rimane parallela. Dopo la lettura Intune, un secondo passaggio GLPI integra le schede trovate per seriale; la ricerca non e completa finche anche questo passaggio non termina. Un errore non viene presentato come assenza del PC.

Se per il seriale Intune (o per il nome, quando manca il seriale) risultano zero o piu schede GLPI attive, la cancellazione mostra un avviso e una seconda conferma esplicita per i soli PC interessati. **Scarica chiavi** salva un file di testo con computer, seriale, ID e password di recupero; **Stampa chiavi** apre la scelta della stampante e gestisce report su piu pagine. La copia e facoltativa: l'operatore puo confermare il rischio di perdita senza crearla. Le password sono rilette soltanto su richiesta di copia/stampa e non compaiono nell'anteprima o negli eventi di avanzamento.

La conferma senza GLPI non sceglie una scheda a caso e non scrive Note GLPI. Gli altri PC del lotto conservano il backup verificato. Errori di recupero, identita cambiate, chiavi cambiate e oggetti AD protetti non vengono ignorati. Il backend richiede i nomi esatti dei PC confermati e ripete i controlli prima delle cancellazioni. **Archivia BitLocker** continua a richiedere una scheda GLPI univoca; una conferma di perdita non viene trattata come archiviazione riuscita. Le Note GLPI preesistenti restano inalterate.

## Identita hybrid AD / Entra (1.0.22)

La colonna **Identita AD/Entra** confronta `deviceId` Entra con `ObjectGUID` AD soltanto per le registrazioni `trustType=ServerAd`. `Workplace` (registered) e `AzureAd` (joined cloud) sono non applicabili. Ogni registrazione ha il proprio esito: un registered omonimo non nasconde un hybrid discordante. L'Object ID Entra e l'ID gestionale Intune non vengono confrontati con il GUID AD.

- **Corrisponde**: stesso GUID. Le repliche lette su piu DC rappresentano la stessa identita.
- **Non corrisponde**: oggetti AD omonimi con GUID diverso; il dettaglio conserva gli identificativi e segnala anche un eventuale oggetto atteso trovato con un altro nome.
- **Assente in AD**: ricerca completa per nome/GUID senza corrispondenze.
- **Non verificabile**: fonte esclusa, tipo di join o identificativi non validi, DC irraggiungibile o lettura incompleta.

Per gli hybrid senza una corrispondenza gia letta viene eseguita una ricerca LDAP mirata tramite GUID, suddivisa in lotti e sempre sul lettore AD sequenziale. La ricerca attende anche questo passaggio prima di concludersi. Il dettaglio mostra il nome AD effettivo quando il computer e stato rinominato. La correlazione non aggiunge automaticamente l'oggetto rinominato alla selezione di eliminazione.

Prima delle cancellazioni il backend rilegge il tipo di join e i metadati AD. Una discordanza provata richiede la conferma separata **HybridIdentityConsent**, limitata ai PC elencati, distinta dai consensi per figli AD, associazione GLPI e perdita chiavi. Una modifica dopo l'anteprima invalida la conferma. L'archiviazione senza cancellazione non richiede questa conferma.

## Diagnostica BitLocker (1.0.22)

**Leggi chiavi** continua a partire da Intune e a usare AD come riserva. Il report separa sessione effettiva del processo lettore, ricerca Intune, validazione Azure AD Device ID, elenco metadati, richiesta della password e validazione della risposta. Mostra conteggi, Device ID e Recovery Key ID, distinguendo un dispositivo assente da una lista di chiavi vuota.

Il parser gestisce anche il resoconto HTTP con intestazioni prodotto dal SDK Graph 2.41.1, oltre al JSON puro. Conserva HTTP, codice Graph, request-id e tipo dell'eccezione; gli errori locali hanno codici distinti, ad esempio `InvalidIdentifier`, `MissingPassword`, `InvalidPassword` e `MissingCollection`. La finestra offre **Copia diagnostica** anche quando nessuna chiave viene recuperata. Il testo copiato e costruito dai soli dati diagnostici e non include password di recupero, token, corpi di risposta o intestazioni complete.

La verifica iniziale dei metadati rimane **Parziale**: non viene letta una password durante l'accesso. La lettura effettiva avviene soltanto con l'operazione richiesta. Nessuna nuova autorizzazione o richiesta di login viene introdotta nelle funzioni. Gli errori di lettura restano bloccanti per backup ed eliminazioni; il nuovo report permette di diagnosticare il problema reale del tenant senza attribuirlo automaticamente ai permessi.

Riferimenti Microsoft: [attributi sincronizzati AD/Entra](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-sync-attributes-synchronized#windows-10), [trustType del dispositivo](https://learn.microsoft.com/en-us/graph/api/resources/device), [lettura chiave e ruoli delegati](https://learn.microsoft.com/en-us/graph/api/bitlockerrecoverykey-get). Formato degli errori del SDK fissato: [InvokeMgGraphRequest](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/v2.41.1/src/Authentication/Authentication/Cmdlets/InvokeMgGraphRequest.cs), [HttpMessageFormatter](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/v2.41.1/src/Authentication/Authentication/Helpers/HttpMessageFormatter.cs).

## Lettura della password con proiezione key (1.0.23)

La richiesta della singola chiave usa esattamente `GET /informationProtection/bitlocker/recoveryKeys/{id}?$select=key`, come nella documentazione Microsoft. In precedenza la proiezione includeva anche i metadati. Il lettore gestisce anche una risposta con la sola proprieta `key`: l'ID richiesto e gia stato verificato nell'elenco filtrato per Device ID; qualsiasi ID presente nella risposta deve coincidere. Volume e data mancanti vengono ripresi dall'elenco metadati. Restano i controlli di formato e checksum e il divieto di trattare una risposta senza password come assenza di chiavi.

La diagnostica distingue `MissingKeyField`, `EmptyKeyField`, `InvalidKeyType`, `InvalidKeyFormat`, `InvalidPassword` e `InvalidKeyResponse`. Riporta la struttura della risposta e se i campi sono presenti, senza includere password, token o valori grezzi. Una risposta HTTP riuscita viene distinta da una password effettivamente validata. Riferimento: [richiesta Microsoft della password BitLocker](https://learn.microsoft.com/en-us/graph/api/bitlockerrecoverykey-get).

## Note leggibili e archivio AD in sola lettura (1.0.24)

Le nuove Note native GLPI sono testo semplice, coerente con il campo textarea di GLPI 10.0.11. Il formato V2 contiene etichette leggibili e la chiave in chiaro; non invia tag HTML o un blocco JSON. Il lettore continua a supportare le vecchie note V1. Ripetendo Archivia BitLocker su una chiave V1 viene aggiunta una sola nota V2 leggibile: tutte le note precedenti restano intatte. Le esecuzioni successive riusano la copia V2; Leggi archivio deduplica la vista e blocca password/seriali discordanti per lo stesso ID.

Archivia BitLocker interroga su AD soltanto i figli `msFVE-RecoveryInformation`. La protezione dalla cancellazione del computer o del figlio non impedisce la lettura e non viene rimossa. Le eliminazioni mantengono la verifica di tutti i discendenti, dei relativi GUID e delle protezioni. La modalita di lettura rimane vincolata al piano di sola archiviazione e viene mantenuta anche nelle riletture prima del salvataggio.

La diagnostica AD distingue computer visibili, oggetti di recupero visibili e lettura della password. Un risultato con zero oggetti visibili puo indicare assenza di backup AD oppure restrizioni ACL; il confronto hybrid positivo non certifica il salvataggio di una chiave in AD. Gli errori non vengono convertiti in zero chiavi. Gli identificativi non validi riportano origine, DC e DN, senza inserire password o eccezioni grezze nei report.
