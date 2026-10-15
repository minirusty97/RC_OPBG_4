# Computer Explorer — console di ricerca

Aggiornamento: 15 ottobre 2026. Versione funzionale integrata in `main`.

## Fase attuale

`Start-ComputerExplorer.ps1` è la prima interfaccia Windows Forms per la ricerca aggregata AD / Entra ID / Intune / GLPI. `ComputerExplorer.Core.psm1` gestisce letture, raccolte cloud, cache e aggregazione. `ComputerExplorer.Parallel.psm1` coordina un pool di massimo otto lettori indipendenti. Riutilizza `Test-AdLookup.ps1 -PassThru` per AD e `GLPI.Inventory.psm1` per GLPI.

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

I token GLPI vengono letti dal `.env` nella cartella degli script tramite `Read-ExplorerGlpiCredentials`, poi conservati come SecureString per la sessione della console. Lo stesso caricamento è usato da Test-GlpiLookup.ps1. Il `.env` contiene GLPI_USER_TOKEN e GLPI_APP_TOKEN in chiaro, è escluso da Git e non viene scritto dalla UI; il repository include solo il modello vuoto `.env.example`. Se manca o è incompleto resta disponibile il prompt. Il parser legge dati senza eseguire espressioni, rifiuta duplicati e righe malformate senza mostrare i valori. Per ricaricare modifiche al file si riapre la finestra. Il JSON locale è escluso da Git e contiene l'URL effettivo già verificato dall'utente.

Graph usa Microsoft.Graph.Authentication. Riutilizza la sessione e gli ambiti sufficienti già presenti; se mancano, avvia il login interattivo mantenendo tenant, client e ambiti correnti quando disponibili. Gli ambiti aggiunti sono quelli già autorizzati per il tool: Directory.AccessAsUser.All e DeviceManagementManagedDevices.ReadWrite.All. Una sessione applicativa preconfigurata non viene sostituita da una delegata. La prima implementazione supporta l'endpoint Global graph.microsoft.com.

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

La finestra richiama Invoke-ComputerExplorerParallelSearch. GLPI e i lettori dei singoli DC partono indipendentemente. Un solo lavoro esegue Connect-ExplorerGraph per le fonti cloud selezionate; al termine partono Entra e Intune contemporaneamente, riutilizzando la sessione statica del Graph SDK nello stesso processo. Nessun lettore cloud esegue un proprio login.

Il pool ha al massimo otto runspace STA: con la configurazione attuale possono procedere i cinque DC, Entra, Intune e GLPI. Ogni lettore AD usa il parametro DomainController di Test-AdLookup.ps1, limitato ai DC configurati. Gli esiti AD vengono riuniti per DC; la presenza rimane grigia finché tutti i DC non hanno terminato o se una verifica fallisce.

I risultati vengono pubblicati progressivamente. Le fonti ancora in attesa restano grigie; un errore Graph non ferma AD o GLPI. La UI riunisce gli aggiornamenti ravvicinati e abilita la rimozione solo dopo la fine della ricerca. Le cancellazioni conservano il piano e l'ordine sequenziale già implementati.

Alla chiusura del lavoro la finestra applica anche il risultato finale restituito dal coordinatore. Questo evita che una ricerca terminata durante il ridisegno della griglia rimanga visualizzata come «in corso» con Elimina disabilitato. Le prove di completamento usano pipeline asincrone reali e forzano questa sovrapposizione; ricerche ancora in esecuzione, fallite o interrotte mantengono la rimozione disabilitata.

Ogni API mantiene la propria paginazione sequenziale. Il connettore GLPI mantiene una sola sessione e la lettura ordinata delle schede; il suo tempo può dominare ricerche con molti risultati. Il parallelismo riduce le attese fra sorgenti, senza promettere un rapporto fisso di accelerazione.

L'annullamento invia lo stop a tutti i lavori, ne attende la chiusura e dispone il pool. Le cache parziali non vengono pubblicate; le cache complete restano condivise e il refresh forzato viene rispettato.

Riferimenti: [runspace pool PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/developer/hosting/creating-multiple-runspaces) e [GraphSession thread-safe del Graph SDK](https://github.com/microsoftgraph/msgraph-sdk-powershell/blob/main/src/Authentication/Authentication.Core/Common/GraphSession.cs).
