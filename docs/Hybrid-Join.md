# Verifica Hybrid Join

Modulo derivato da `Verifica-HybridJoin-OU-Entra-Con-Pulizia.ps1`, integrato
nella suite con accesso delegato dal wrapper e impostazioni condivise.

Da Impostazioni → Hybrid Join configurare server AD, profondita e OU.
Importa OU dallo script legge i parametri costanti del file originale, senza
eseguirlo. Le OU non sono inserite nel pacchetto pubblico e vengono salvate
solo nella configurazione personale. Se il
server e vuoto viene usato il primo DC configurato. La lettura AD usa le
credenziali Windows correnti e richiede RSAT ActiveDirectory. Le OU possono
essere relative al dominio o DN completi nello stesso dominio. OU sovrapposte
non duplicano il computer con lo stesso GUID. Una OU non leggibile interrompe
la ricerca, senza presentarla come vuota.

All’apertura parte automaticamente una scansione completa delle OU configurate,
di tutte le pagine Entra e, se autorizzato, di Intune. La vista iniziale e
**Tutti**. **Aggiorna dati / F5** ripete la scansione completa.
**Filtra elenco** e il filtro di stato agiscono sui dati gia caricati: non
limitano la lettura alle macchine cercate e non avviano nuove richieste. Il
contatore mostra dispositivi visualizzati sul totale e selezionati.
Il confronto affianca nomi e GUID: per `ServerAd` il Device ID Entra deve
corrispondere a ObjectGUID AD. La corrispondenza per GUID ritrova anche una
registrazione Hybrid con nome diverso. Workplace e AzureAd non sono valutati
come identita AD. Duplicati, MDM, proprieta, account disabilitati e altre
anomalie restano visibili. Filtri, dettagli, selezione multipla ed esportazione
CSV consentono di esaminare le eccezioni.

GLPI usa i token delle impostazioni. Il seriale proviene dalle registrazioni
Intune collegate tramite Device ID Entra, mai da un Managed Device ID usato
come identificativo Entra. La ricerca GLPI preferisce il seriale, anche con
nome GLPI diverso. Se una ricerca seriale completata non trova corrispondenze,
prova anche il nome esatto, come per i PC senza seriale. La consultazione
copre tutte le entità autorizzate al profilo API GLPI. Una scheda trovata
solo per nome viene mostrata come Presente (solo nome), con avviso se il
seriale Intune manca o differisce in GLPI. L identita hardware non viene
confermata automaticamente e i duplicati restano espliciti. Un errore API
non attiva il ripiego e resta Non verificabile.
Le letture GLPI dei dettagli sono raggruppate e riutilizzate nella singola
scansione; la cache non e condivisa tra ricerche o credenziali. Stato, ID, gruppo, CENSITO,
inventario e dati Intune sono visibili nei dettagli. Le ricerche raggruppate
considerano ogni seriale o nome come alternativa. **Apri scheda GLPI**
apre l'unica scheda associata alla riga selezionata. Assenza, duplicati
ed errori di lettura sono distinti.

## Pulizia Registered

Selezionare i computer, usare Pulizia Registered e scegliere gli Object ID
Workplace da verificare. Nessuna casella e preselezionata. Sono mostrati i
proprietari/utenti registrati disponibili e le eventuali relazioni non
leggibili; non rappresentano l'utente attualmente connesso a Windows.

La preparazione rilegge nome, Device ID, trust type, sincronizzazione e stato
MDM. Il piano ammette solo gli Object ID selezionati, solo Workplace non
sincronizzati da AD. Le altre registrazioni omonime restano intatte. Non
vengono cancellati oggetti AD o registrazioni Intune.

La conferma e il backend sono gli stessi di Computer Explorer: recupero
BitLocker dell'oggetto selezionato, archivio append nelle Note GLPI e rilettura
prima della cancellazione. Per assenza/duplicati GLPI rimangono conferma
separata del rischio e download/stampa facoltativi delle chiavi. Errori di
lettura reali bloccano l'operazione. I piani scadono dopo cinque minuti e le
identita vengono rilette prima della DELETE. Per una selezione solo Entra
l'archivio GLPI basato sul nome richiede la conferma manuale gia prevista.

Il modulo richiede `entra-read` per aprirsi. Intune e opzionale per il
confronto seriali. La pulizia richiede `entra-remove`, quindi il consenso
delegato `Directory.AccessAsUser.All` e un ruolo Entra effettivamente ammesso.
Il consenso non viene richiesto all'uso della funzione. L'app dedicata senza
quel consenso resta utilizzabile in lettura. La lettura delle chiavi cloud
richiede `BitlockerKey.Read.All` e i diritti del tecnico.

I resoconti delle operazioni sono salvati in `Reports/Hybrid` sotto la cartella
dati personale, senza password BitLocker. Dopo un'operazione vengono riletti
i dati. Il risultato dell'operazione rimane nella scheda Resoconto operazioni.
