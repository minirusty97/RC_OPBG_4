# Stato condiviso per riprendere il lavoro

Repository: `minirusty97/RC_OPBG_4`. Consultare sempre il main e la release
effettiva. La **1.5.1** mostra l’ultimo inventario GLPI in Verifica Hybrid Join.
La **1.5.0** aggiorna Verifica Hybrid Join. La **1.4.1** limita Elimina in Computer
Explorer alle presenze verificate per riga e rifinisce il wrapper.
La **1.4.0** integra la prova AD parallela, la diagnostica per ricerca
e il pannello di stato del wrapper. La **1.3.3**
attende la conferma di avvio dell'installazione OTA e registra l'esito. La **1.3.2** ripristina la ricerca su tutti i
DC in Computer Explorer e confronta i GUID Hybrid già letti sul DC
principale. La **1.3.1** aggiorna la finestra di Gestione
Ring con riepilogo, colonne di inventario GLPI, filtri locali per colonna e
pulsanti in basso. La **1.3.0** verifica l'accesso salvato
all'apertura e cerca le schede Hybrid e Ring nelle entità autorizzate al
profilo API GLPI. La 1.2.2 corregge le ricerche GLPI per seriale e nome
raggruppate e il pulsante Apri scheda GLPI. La 1.2.1 corregge il blocco di cancellazione
per figli AD con solo DN leggibile, con consenso esplicito e normale
eliminazione LDAP del singolo figlio. La 1.2.0 include
ricerca AD su un DC configurabile, dettagli GLPI raggruppati con cache per
scansione, ripiego per nome esatto dopo seriale GLPI senza risultati e
spostamenti Ring confermati. I moduli Hybrid/Ring continuano a eseguire una
scansione completa automatica, vista Tutti e filtri locali; F5 rilegge tutto.

| Modulo | Entry point | Backend e documentazione |
| --- | --- | --- |
| Computer Explorer | Start-ComputerExplorer.ps1 | ComputerExplorer.*, BitLocker.Archive.psm1, GLPI.Inventory.psm1; docs/Computer-Explorer.md e docs/Ricerca-Computer.md |
| Verifica Hybrid Join | Start-HybridJoin.ps1 | HybridJoin.Core.psm1; docs/Hybrid-Join.md |
| Gestione Ring Intune | Start-RingManager.ps1 | RingManager.Core.psm1; docs/Gestione-Ring.md |

Il wrapper ripristina in modo silenzioso l'account delegato confermato.
Il pulsante Accesso in basso gestisce il login interattivo. Il pannello
compatto indica in rosso una sessione che richiede Accesso. Entra, Intune
e gruppi mostrano separatamente l'esito delle letture. Stato accesso
include anche l'utente API GLPI. Componenti include RSAT, SDK Graph,
raggiungibilità del repository e stato dell'aggiornamento. Ogni modulo distingue
lettura e scrittura e usa la sessione verificata del wrapper.
GLPI resta alla versione 10.0.11 senza plugin aggiuntivi. Le Note BitLocker
sono in chiaro per recupero estremo, append senza sovrascrittura, con lettura
compatibile degli archivi V1. Non riportare chiavi reali in log o repository.

Hybrid Join legge le OU configurabili su un solo DC e confronta GUID AD /
Device ID per ServerAd. I riepiloghi contano i PC
unici e l'attestazione Intune per OU. La pulizia parte dagli Object ID
Workplace dell'intera scansione, poi riusa la scelta per ID e il percorso
di archivio/conferma di Computer Explorer.

Ring Intune usa gruppi selezionati dalle impostazioni, salvati per ID con
flag di controllo e Modifica. Nessun gruppo e preselezionato; Ring99 e escluso.
I candidati restano Windows Hybrid Corporate MDM abilitati. Sono ammesse
assegnazioni e spostamenti di PC gia assegnati con anteprima esplicita:
aggiunta/verifica destinazione, poi rimozione /$ref delle sole origini dirette
confermate e modificabili. Le origini solo monitorate o ereditate bloccano
lo spostamento. Errori dopo l aggiunta mantengono la destinazione e un esito
parziale; nessun rollback o ritentativo automatico della scrittura.

La ricerca di Computer Explorer usa tutti i DC configurati e un DC
principale per il confronto Hybrid. Per la cancellazione, il controllo
AD rilegge tutti i DC e verifica i GUID mostrati sulle rispettive repliche.
GLPI preferisce il seriale Intune: solo dopo una ricerca seriale completata
senza risultati usa nome esatto con avviso e identita hardware da verificare.
La cache di inventario resta per scansione/credenziali e non sostituisce le
riletture fresche di archivio/cancellazione.

I controlli CI coprono backend con dati sintetici, finestre WinForms su
Windows PowerShell 5.1, installer e aggiornamenti OTA. Prestazioni,
visibilita dell'inventario e diritti effettivi dipendono dalla
configurazione di ciascuna installazione.

Per chat separate e regola versioni: docs/Sviluppo-Moduli.md e
docs/Versionamento.md. Aggiornare questo stato a ogni lavoro concluso,
distinguendo test automatici e osservazioni reali del tecnico.

## Correzione 1.2.1: figli AD non leggibili

Con autorizzazioni di lettura parziali, AD puo restituire il DN del
figlio con classe e GUID vuoti. Il filtro msFVE puo restituire zero
risultati in questo caso.

La 1.2.1 usa la cancellazione ordinaria del singolo figlio per
DN, previa conferma esplicita del rischio chiavi AD, e conserva i controlli
sull identita/protezione del computer. Mai tree-delete o modifica ACL. Si
archiviano le chiavi recuperate e si segnala la copertura AD non garantita.
La release 1.2.1 ha superato i controlli Windows, installer e OTA.
Il comportamento dei figli con solo DN e descritto in
docs/Eliminazione-Figli-AD.md.

## Correzione 1.2.2: ricerca e apertura schede GLPI

In GLPI 10.0.11 i criteri di una richiesta sono elaborati nell'ordine di
arrivo. Il primo criterio non usa il proprio operatore. Un criterio
successivo senza operatore viene combinato con AND. Il connettore ora
dichiara OR su ogni seriale o nome delle ricerche raggruppate.

Il pulsante Apri scheda GLPI carica esplicitamente il modulo che legge
la configurazione. Gli errori di apertura appaiono nella barra di stato.
I test riproducono l'ordine invertito dei criteri e il clic nelle finestre
native. Le schede visibili al profilo del token GLPI vanno confermate
nell'ambiente del tecnico.

## Accesso e inventario in 1.3.0

Al primo accesso confermato si salva un riferimento all'account. Graph
PowerShell e Windows gestiscono la cache protetta dei token. All'apertura
si verifica il medesimo account nella configurazione attiva, con
acquisizione silenziosa e letture limitate di Entra, Intune e gruppi.
Le autorizzazioni alle scritture e alle chiavi sono valutate dai servizi
quando si eseguono le operazioni.

Hybrid e Ring estendono la consultazione a tutte le entità del profilo API.
Su GLPI 10.0.11 il cambio di contesto seleziona tutte le entità quando
`entities_id` viene omesso. Un errore di selezione rende l'inventario
non verificabile. I test coprono una scheda fuori dall'entità predefinita
e il ripristino della sessione con risposte sintetiche. La verifica con
i criteri di accesso del tenant e il profilo GLPI in uso avviene sul posto.

## Gestione Ring in 1.3.1

La scansione espone i contatori del vecchio script e conta i dispositivi
per Ring senza altre richieste a Entra. Il Fornitore e il numero inventario
della scheda GLPI alimentano Reparto GLPI e Asset ID. La lettura delle
informazioni amministrative è attivata solo per Ring. I test coprono i dati
GLPI sintetici, inclusi un inventario vuoto e un fornitore non leggibile,
e la finestra WinForms con i filtri locali. La disponibilità del Fornitore
dipende dai diritti del profilo API GLPI effettivo.

## Ricerca AD in 1.3.2

Il DC principale è il primo della coda, scelto con l'impostazione esistente
oppure riconosciuto come dc1 o srvdc1. La ricerca interroga anche le altre
repliche con il filtro LDAP Name, DNSHostName e sAMAccountName. Il
confronto Hybrid e Intune usa soltanto il risultato sul DC principale
già letto. I test sintetici coprono la presenza sulle sole repliche
secondarie, la discordanza, il DC principale in errore e la copertura
con la configurazione precedente. Per confrontare i tempi dei filtri
serve una misura sul DC con gli stessi dati.

## Aggiornamento OTA in 1.3.3

Il processo di aggiornamento esegue lo script dalla cartella installata
e lavora nella directory del download. Il wrapper resta aperto fino alla
conferma di avvio. Gli errori d'avvio sono visibili e il processo registra
l'esito in `update-install.log`. Restano previsti il controllo del checksum,
l'attesa della chiusura dei processi e la riapertura dopo l'installazione.

Il test Windows parte dalla finestra di un'installazione 1.3.1 con
l'aggiornatore estratto dal nuovo setup. Usa come risposte locali i file
reali della build, prova l'installazione e il riavvio e controlla
configurazione e credenziali cifrate. La riproduzione isolata con
l'aggiornatore precedente ha completato il ciclo 1.3.1 → 1.3.2.

## Eliminazione e aspetto del wrapper in 1.4.1

Il piano di Computer Explorer usa gli ID delle origini confermate sulla
riga selezionata. La verifica prima dell'anteprima e quella prima delle
scritture applicano lo stesso perimetro per riga. Identità aggiunte
durante la rilettura richiedono una nuova ricerca. Il flusso separato di
archiviazione BitLocker conserva le origini selezionabili.

I test con dati sintetici coprono le selezioni miste, gli ID comparsi dopo
la ricerca e le origini non verificate. In locale, con rete disabilitata,
sono passati 275 controlli. La pipeline della PR #38 ha superato 338 controlli
Windows, comprese le prove WinForms per GLPI in Stato accesso, gli angoli e i
colori dei pulsanti. Ha verificato anche installazione pulita, migrazione e
aggiornamento OTA con dati di prova.


## Verifica Hybrid Join in 1.5.0

Il ramo della 1.5.0 riusa la lettura AD isolata di Computer Explorer e il
Fornitore/numero inventario di Gestione Ring. Entra e Intune sono letti in
parallelo alla scansione AD. Il totale deduplica i PC per GUID. I conteggi
per OU distinguono Intune OK e non verificabile. La griglia e il CSV
includono la modifica AD sul DC interrogato, l'attività approssimativa
Entra e l'aggiornamento della scheda GLPI. I filtri operano in locale.
Computer si cerca con Filtra per nome. Le date sono ordinabili.
Verifica e pulisci Registered parte dall'inventario
completo e apre la scelta dei singoli Object ID.

Le prove sintetiche coprono la scelta di un solo DC, la lettura AD e cloud
in parallelo, le OU sovrapposte, Intune con duplicati e fonte non disponibile. Tempi, copertura e diritti
del profilo GLPI vanno verificati sulla rete aziendale.

## Ultimo inventario GLPI in 1.5.1

Verifica Hybrid Join usa `last_inventory_update` nella griglia e nel CSV.
I test con schede GLPI simulate distinguono la data di inventario da
quella di modifica della scheda.
