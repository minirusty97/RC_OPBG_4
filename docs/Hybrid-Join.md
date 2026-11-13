# Verifica Hybrid Join

Modulo derivato da `Verifica-HybridJoin-OU-Entra-Con-Pulizia.ps1`, integrato
nella suite con accesso delegato dal wrapper e impostazioni condivise.

## Scansione e riepilogo

Da **Impostazioni → Hybrid Join** configurare profondità e OU. **Importa OU
dallo script** legge i parametri costanti del file originale. Le OU possono
essere relative al dominio o DN completi e restano nella configurazione personale.

La ricerca parte all'apertura. **Aggiorna** (F5) rilegge le OU su un solo DC,
tutte le pagine Entra e, se autorizzato, Intune. Il modulo usa il server
impostato in Hybrid Join oppure il DC principale di Computer Explorer
(dc1 o srvdc1 in automatico, se configurato). Il lettore AD isolato ha
un limite di 30 secondi. Entra e Intune vengono letti in parallelo.
**Riepilogo fonti** indica il server usato, i tempi AD e gli esiti Intune
e GLPI. La lettura AD usa le credenziali Windows correnti e richiede
RSAT ActiveDirectory.

Il confronto tra ObjectGUID AD e Device ID Entra si fa per ServerAd
e riconosce anche un dispositivo Hybrid rinominato. Workplace e AzureAd
sono visibili nei dettagli.

**Riepilogo generale** mostra i PC unici, l'esito dell'identità Hybrid,
l'attestazione Intune e quanti PC hanno registrazioni Registered. **OU
analizzate** riporta PC compresi, Intune OK e Intune N/D. Un PC in OU
sovrapposte vale una volta in ciascuna OU e una volta nel totale generale.
Se il DC configurato non completa la lettura delle OU, la scansione segnala l’errore.

**Intune OK** richiede una sola identità Hybrid abilitata, gestita da MDM e
coerente con il GUID AD, con un solo record Windows in Intune associato
tramite Azure AD Device ID. La colonna **Seriale Intune** usa solo quel
collegamento per GUID. **Attestazione Intune** mostra **OK**, **Da
regolarizzare** oppure **Non verificabile**. Il riepilogo conta come
**Intune N/D** le righe non verificabili per errore di lettura o permesso
mancante.

## Griglia e GLPI

La griglia mostra Computer, Hybrid, Identità AD/Entra, Registered, Seriale
Intune, Attestazione Intune, Stato GLPI, Reparto GLPI, OU, Asset ID, Censito
e GLPI. Seguono Ultima modifica AD, Ultima attività Entra e Ultimo
inventario GLPI.
**Filtra per nome** si combina con **Filtra per campo**. Il secondo filtro
accetta un valore della lista o un frammento di testo. Nome e date sono
esclusi dal selettore per campo. Entrambi i filtri agiscono sui dati già
caricati. **Esporta CSV** usa le intestazioni della griglia e aggiunge in
italiano i dettagli delle fonti, tra cui **Motivo attestazione Intune**.

Ultima modifica AD usa Modified (whenChanged) sul DC interrogato. Ultima
attività Entra usa approximateLastSignInDateTime, riportata in ora locale.
Ultimo inventario GLPI usa `last_inventory_update`, in ora del server GLPI.
Per più oggetti Entra o schede GLPI, la griglia mostra la data valida più
recente e i dettagli mostrano le date individuali. Le date si possono
ordinare in griglia. I valori mancanti compaiono come trattino in griglia
e come campo vuoto nel CSV.

GLPI cerca in tutte le entità autorizzate al profilo API. Usa prima il
seriale Intune valido, poi il nome esatto per i PC senza seriale o per cui
la ricerca seriale si è conclusa senza schede. Gli errori di lettura, i
duplicati e le corrispondenze per solo nome restano visibili. **Reparto GLPI**
usa il Fornitore della scheda e **Asset ID** il numero inventario, come in
Gestione Ring. **Apri su GLPI** apre l'unica scheda associata alla riga
selezionata.

## Pulizia Registered

**Verifica e pulisci Registered** cerca i candidati Workplace in tutte le OU
dell'ultima scansione, indipendentemente dai filtri e dalla selezione della
griglia. La finestra successiva mostra i singoli Object ID, i proprietari e
gli utenti registrati disponibili. Le caselle partono vuote. Dopo la scelta
degli oggetti, il modulo prepara l'anteprima per la conferma.

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
