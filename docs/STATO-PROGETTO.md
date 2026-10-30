# Stato condiviso per riprendere il lavoro

Repository: `minirusty97/RC_OPBG_4`. Consultare sempre il main e la release
effettiva: questo documento descrive la versione sorgente **1.1.0**, che
introduce due moduli oltre a Computer Explorer 1.0.24.

| Modulo | Entry point | Backend e documentazione |
| --- | --- | --- |
| Computer Explorer | Start-ComputerExplorer.ps1 | ComputerExplorer.*, BitLocker.Archive.psm1, GLPI.Inventory.psm1; docs/Computer-Explorer.md |
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
flag di controllo e destinazione. Nessun gruppo e preselezionato; Ring99 e escluso.
Le aggiunte riguardano solo orfani Windows Hybrid Corporate MDM abilitati;
gruppi non leggibili interrompono la ricerca e le appartenenze non si rimuovono.

Verifica: test isolati dei backend, finestre WinForms su Windows PowerShell
5.1, regressioni Computer Explorer e installer/OTA in CI. I test usano dati
sintetici e non provano i diritti del tenant aziendale. Restano da verificare
dal tecnico in ambiente aziendale le OU effettive, i gruppi scelti, eventuali
consensi nuovi e i diritti sulle singole chiavi BitLocker AD. Il successo su
Intune e sull'archivio GLPI era stato confermato durante il lavoro sulla 1.0.23;
la presenza di copie delle chiavi in AD non e stata confermata.

Per chat separate e regola versioni: docs/Sviluppo-Moduli.md e
docs/Versionamento.md. Aggiornare questo stato a ogni lavoro concluso,
distinguendo test automatici e osservazioni reali del tecnico.
