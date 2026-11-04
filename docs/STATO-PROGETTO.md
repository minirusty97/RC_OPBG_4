# Stato condiviso per riprendere il lavoro

Repository: `minirusty97/RC_OPBG_4`. Consultare sempre il main e la release
effettiva: questo documento descrive la versione sorgente **1.2.0**. Include
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

La lettura ordinaria di Computer Explorer preferisce srvDC1 nell elenco
personale, altrimenti il primo DC. Le impostazioni consentono un DC diverso
o tutti per diagnostica. BitLocker e cancellazioni conservano tutti i DC.
GLPI preferisce il seriale Intune: solo dopo una ricerca seriale completata
senza risultati usa nome esatto con avviso e identita hardware da verificare.
La cache di inventario resta per scansione/credenziali e non sostituisce le
riletture fresche di archivio/cancellazione.

Verifica: test isolati dei backend, finestre WinForms su Windows PowerShell
5.1, regressioni Computer Explorer e installer/OTA in CI. I test usano dati
sintetici e non provano i diritti del tenant aziendale. Restano da verificare
dal tecnico in ambiente aziendale il tempo effettivo di Port-, le schede
GLPI prima segnalate assenti, le OU effettive, i gruppi scelti, eventuali
consensi nuovi e i diritti sulle singole chiavi BitLocker AD. Il successo su
Intune e sull'archivio GLPI era stato confermato durante il lavoro sulla 1.0.23;
la presenza di copie delle chiavi in AD non e stata confermata.

Per chat separate e regola versioni: docs/Sviluppo-Moduli.md e
docs/Versionamento.md. Aggiornare questo stato a ogni lavoro concluso,
distinguendo test automatici e osservazioni reali del tecnico.

## Diagnosi e correzione in prova: figli AD non leggibili

Il tecnico ha confermato che mancano i diritti AD alla lettura delle informazioni
BitLocker. Il DN del figlio viene restituito mentre classe e GUID rimangono
vuoti; il filtro msFVE puo quindi restituire zero. La cancellazione manuale
del computer dallo snap-in rimane un operazione distinta dalla lettura chiavi.

Il ramo di diagnosi prepara la cancellazione ordinaria del singolo figlio per
DN, previa conferma esplicita del rischio chiavi AD, e conserva i controlli
sull identita/protezione del computer. Mai tree-delete o modifica ACL. Si
archiviano le chiavi recuperate e si segnala la copertura AD non garantita.
Dettagli e limiti: docs/Eliminazione-Figli-AD.md. La release stabile resta 1.2.0
e la ricompilazione e sospesa durante i test richiesti dal tecnico.
