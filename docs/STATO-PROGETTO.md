# Stato condiviso per riprendere il lavoro

Repository: `minirusty97/RC_OPBG_4`. Consultare sempre il main e la release
effettiva. La versione sorgente **1.2.2** corregge le ricerche GLPI per
seriale e nome raggruppate e il pulsante Apri scheda GLPI di Gestione Ring
e Verifica Hybrid Join. La 1.2.1 corregge il blocco di cancellazione
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

Decisioni condivise: accesso delegato unico dal pulsante in basso; niente
certificati o login dalle funzioni. Ogni modulo distingue lettura e scrittura.
GLPI resta alla versione 10.0.11 senza plugin aggiuntivi. Le Note BitLocker
sono in chiaro per recupero estremo, append senza sovrascrittura, con lettura
compatibile degli archivi V1. Non riportare chiavi reali in log o repository.

Hybrid Join legge OU configurabili e confronta GUID AD / deviceId per
ServerAd; Registered e ignorato nel confronto GUID. La pulizia sceglie gli
Object ID Workplace e riusa il percorso di archivio/conferma di Computer
Explorer, preservando le altre registrazioni omonime.

Ring Intune usa gruppi selezionati dalle impostazioni, salvati per ID con
flag di controllo e Modifica. Nessun gruppo e preselezionato; Ring99 e escluso.
I candidati restano Windows Hybrid Corporate MDM abilitati. Sono ammesse
assegnazioni e spostamenti di PC gia assegnati con anteprima esplicita:
aggiunta/verifica destinazione, poi rimozione /$ref delle sole origini dirette
confermate e modificabili. Le origini solo monitorate o ereditate bloccano
lo spostamento. Errori dopo l aggiunta mantengono la destinazione e un esito
parziale; nessun rollback o ritentativo automatico della scrittura.

La lettura ordinaria di Computer Explorer usa un DC configurabile.
Le impostazioni consentono di consultare tutti i DC per diagnostica.
BitLocker e cancellazioni continuano a usare tutti i DC configurati.
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
