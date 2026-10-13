# Computer Explorer — proposta iniziale

Data: 13 ottobre 2026. Base: Remove-Computer-FullTool.ps1, versione con ricerca esatta AD / Entra / Intune.

## Obiettivo e fase attuale

Evolvere il tool in una console Windows di ricerca e verifica dei computer. Il branch di sviluppo contiene il progetto della ricerca e la base del connettore GLPI. La proposta di interfaccia è stata mostrata nella conversazione. La nuova ricerca aggregata AD / Entra / Intune non è ancora implementata nel tool operativo.

La prima fase riguarda ricerca e consultazione. La rimozione verrà collegata al dettaglio del computer selezionato, riutilizzando le funzioni del tool esistente.

## Ricerca

- Una parte del nome trova tutti i nomi che la contengono, senza distinguere maiuscole e minuscole. Esempio illustrativo: SM-PC trova SM-PC-001, SM-PC-002; 003 trova SM-PC-003.
- Ogni nome completo corrisponde a una riga. Nomi simili restano righe diverse; le duplicazioni dello stesso nome vengono contate nelle rispettive colonne.
- I candidati provengono dall'unione delle quattro fonti: una macchina presente solo in GLPI o solo in Entra deve comparire comunque.
- Il pannello di dettaglio conserva gli ID distinti: AD ObjectGUID, Entra ObjectId / DeviceId, Intune managedDeviceId e GLPI ID Computer.
- La lista usa il nome come chiave di consultazione. Le associazioni operative vengono verificate anche con DeviceId Entra e, dove disponibile, seriale o numero inventario. Un conflitto di seriale viene esposto come associazione ambigua.

## Colonne e colori

| Colonna | Verde | Giallo | Rosso | Grigio |
|---|---|---|---|---|
| AD | Presente su tutti i 5 DC: 5/5 | Presente su 1–4 DC, tutti interrogati correttamente | Assente su tutti i DC, tutti verificati | Uno o più DC non verificabili: mostra le presenze note e il numero di DC verificati |
| Entra ID | Una registrazione | Più registrazioni dello stesso nome | Nessuna registrazione, ricerca completata | Ricerca fallita, esclusa o non ancora completata |
| Intune | Una registrazione Windows | Più registrazioni Windows | Nessuna registrazione, ricerca completata | Ricerca fallita, esclusa o non ancora completata |
| GLPI | Un Computer visibile | Più Computer dello stesso nome | Nessun Computer nel contesto GLPI consultato | GLPI non configurato, non raggiungibile o accesso negato |

Stato GLPI e percorso AD hanno colonne proprie. I colori non sostituiscono mai conteggi e testo. Il verde GLPI indica presenza, anche quando lo stato è Ritirato.

Lo stato viene mostrato esattamente come letto da GLPI: Assegnato, Assegnato noleggio, Ritirato, Apparato elettromedicale o qualsiasi altro stato personalizzato. Un eventuale colore dello stato sarà configurabile, senza assumere significati dai suoi ID.

## Dettaglio selezionato

- AD: tabella dei cinque DC con presente / assente / errore, ObjectGUID e percorso CanonicalName. Percorsi o GUID differenti fra DC vengono evidenziati.
- Entra: tutte le registrazioni, tipo di join, ID e ultimo accesso.
- Intune: registrazioni, ID, seriale, utente, ultimo contatto e compliance.
- GLPI: ID asset, stato, seriale, numero inventario, entità e data modifica; apertura della scheda quando l'URL web sarà configurato.

Il percorso visualizzato usa CanonicalName di AD. Il DistinguishedName rimane disponibile nel dettaglio e per le operazioni, evitando di ricostruire l'albero dividendo il DN sulle virgole.

## Prestazioni e interrogazioni

- UI Windows Forms, coerente con il tool attuale. Le interrogazioni verranno eseguite fuori dal thread della finestra, con aggiornamento dei risultati man mano che arrivano.
- AD: filtro LDAP per nome parziale sui cinque DC e caratteri di input correttamente escaped. Presenza, errori e percorsi vengono conservati per ciascun DC.
- Entra: la proprietà displayName supporta startsWith ma non documenta contains. Per una ricerca contiene uniforme si prevede una raccolta paginata dei soli campi necessari, mantenuta in memoria per un intervallo configurabile e filtrata localmente. Un aggiornamento incompleto non sostituisce la raccolta completa precedente.
- Intune: raccolta paginata dei campi necessari e filtro locale per nome; associazione puntuale tramite azureADDeviceId quando disponibile.
- GLPI: ricerca paginata Computer tramite API V1 e risoluzione degli stati reali. La base del connettore inclusa supporta la ricerca contiene.
- Data e ora di aggiornamento visibili per ogni fonte. Valori letti dalla cache sono riconoscibili e vengono ricontrollati prima di operazioni di rimozione.
- La soglia iniziale di due caratteri e la durata della cache sono proposte, da rifinire dopo le prove sul numero reale di macchine.

## Integrazione GLPI predisposta

File inclusi:

- GLPI.Inventory.psm1: esporta Find-GlpiComputer. Usa soltanto GET, apre e chiude una sessione API e restituisce Computer con stato, seriale e numero inventario.
- computer-explorer.config.example.json: URL e opzioni del connettore; GLPI è inizialmente disabilitato perché l'URL effettivo non è stato fornito. Nessun token è memorizzato nel JSON.
- Test-GlpiLookup.ps1: prova separata del connettore, con token inseriti in locale come SecureString; legge automaticamente computer-explorer.config.local.json oppure il percorso indicato con -ConfigPath.
- tests/GLPI.Inventory.Tests.ps1: prove con risposte API simulate, senza collegarsi al server aziendale.

Il connettore individua dinamicamente le colonne Nome e ID di Computer tramite listSearchOptions e legge la denominazione dello stato tramite State. Le pagine vengono raccolte integralmente prima di restituire risultati. Un errore provoca un errore esplicito: la UI dovrà rappresentarlo come Non verificabile.

Il contesto GLPI dipende dal profilo e dalle entità della sessione. Per completare l'integrazione bisogna definire URL di apirest.php, uso dell'App token e profilo / entità da consultare. Il primo connettore usa il contesto predefinito dell'utente API; la selezione delle entità verrà integrata dopo aver concordato il perimetro.

### Prova del connettore

1. Aggiornare il branch con git pull --ff-only. Copiare il JSON già configurato nella cartella del repository con il nome computer-explorer.config.local.json. Se manca, copiarlo da computer-explorer.config.example.json.
2. Nel JSON locale impostare Glpi.BaseUri con l'URL corretto di apirest.php e Glpi.Enabled su true. Impostare UseAppToken in base al client API GLPI.
3. Da Windows PowerShell 5.1 eseguire:

```powershell
.\Test-GlpiLookup.ps1 -NameFragment "SM-PC"
```

4. Inserire User token e, quando richiesto, App token nei prompt locali.

Il connettore è stato verificato in PowerShell con risposte API simulate: risultati singoli e multipli, colonne numeriche e UID, mappe indicizzate per ID, paginazione e interruzione su errore. La versione corretta deve essere riprovata sul GLPI aziendale. La prova non modifica gli asset.

## Rimozione nella futura console

La ricerca parziale produce una lista di candidati. Il comando di rimozione opererà sul computer selezionato e sulle sue registrazioni esatte, dopo una nuova verifica degli ID e dei dati. Il riepilogo indicherà nome completo e oggetti per fonte prima della conferma.

Ordine previsto: Intune, AD, Entra. GLPI contribuisce al controllo dello stato e rimane una fonte di consultazione. La gestione del ritiro o della dismissione nell'inventario GLPI sarà un eventuale progetto distinto, se richiesto.

## Passi successivi

1. Concordare lista, dettaglio e regole di associazione quando il nome o il seriale differiscono.
2. Implementare e provare la ricerca AD sui cinque DC.
3. Aggiungere aggregazione Entra / Intune, cache e aggiornamento asincrono.
4. Verificare il connettore GLPI sul server aziendale e integrare le entità corrette.
5. Collegare le azioni di rimozione al computer selezionato.

## Riferimenti tecnici

- [GLPI REST API V1 ufficiale](https://help.glpi-project.org/documentation/modules/configuration/general/api/api)
- [Microsoft Graph: device](https://learn.microsoft.com/en-us/graph/api/resources/device?view=graph-rest-1.0)
- [Microsoft Graph: managedDevice](https://learn.microsoft.com/en-us/graph/api/resources/intune-devices-manageddevice?view=graph-rest-1.0)
