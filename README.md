# RC_OPBG_4

Tool PowerShell con interfaccia grafica per cercare ed eliminare un computer da Active Directory, Microsoft Entra ID e Microsoft Intune.

## Funzionalità attuali

- Ricerca per nome esatto sui cinque Domain Controller configurati.
- Ricerca delle occorrenze in Entra ID.
- Ricerca delle registrazioni Windows in Intune per nome e DeviceId Entra.
- Eliminazione dalle origini selezionate dopo conferma.
- Ordine di eliminazione: Intune, Active Directory, Entra ID. Un errore di eliminazione Intune interrompe le successive eliminazioni AD ed Entra.

In Intune, l'eliminazione avvia anche il ritiro del dispositivo Windows dalla gestione.

## Requisiti

- Windows PowerShell 5.1.
- Modulo `ActiveDirectory` tramite RSAT.
- Modulo `Microsoft.Graph.Identity.DirectoryManagement` e accesso Graph autorizzato.
- Ambito Graph Entra: `Directory.AccessAsUser.All`.
- Ambito Graph Intune: `DeviceManagementManagedDevices.ReadWrite.All` e un ruolo Intune adeguato.

Il file principale è `Remove-Computer-FullTool.ps1`.

## Lavorare con Git

Prima di iniziare, controllare lo stato. Con la cartella senza modifiche locali, scaricare gli aggiornamenti:

```powershell
git status
git pull --ff-only
```

Dopo aver modificato e verificato lo script:

```powershell
git diff -- Remove-Computer-FullTool.ps1
git add -- Remove-Computer-FullTool.ps1
git diff --cached --stat
git commit -m "Descrizione della modifica"
git push
```

`add` prepara il contenuto, `commit` lo salva nella cronologia locale, `push` invia i commit a GitHub e `pull` riceve gli aggiornamenti.

Per vedere gli ultimi salvataggi:

```powershell
git log --oneline -5
```

## Recuperare una versione salvata

Il commit `ed33c0c` contiene il primo script importato. Per esportare una copia di quella versione nella cartella temporanea di Windows:

```powershell
git archive --format=zip --output="$env:TEMP\RC_OPBG_4-ed33c0c.zip" ed33c0c
```

Sostituire `ed33c0c` con l'identificatore del commit desiderato, ricavato da `git log`. Lo ZIP contiene i file presenti in quel commit; la copia di lavoro corrente resta disponibile.

## Configurazioni

I token si inseriscono nelle richieste di autenticazione o si conservano in file locali esclusi da Git. Il file `.gitignore` contiene le regole di esclusione.

## Connettore GLPI nel branch di sviluppo

`GLPI.Inventory.psm1` ricerca i Computer per frammento del nome e restituisce ID, stato, seriale e numero inventario. Gli stati vengono letti dal server GLPI.

La configurazione usata automaticamente dal test è `computer-explorer.config.local.json`, esclusa da Git. Se esiste già un JSON funzionante, copiarlo qui con questo nome per mantenere l'URL corretto.

In alternativa, creare la configurazione dal modello:

```powershell
Copy-Item .\computer-explorer.config.example.json .\computer-explorer.config.local.json
notepad .\computer-explorer.config.local.json
```

Nel file locale impostare `Glpi.Enabled` su `true`, inserire in `Glpi.BaseUri` l'URL corretto di `apirest.php` e verificare `Glpi.UseAppToken`. I token vengono richiesti nei prompt.

Per provare la ricerca:

```powershell
.\Test-GlpiLookup.ps1 -NameFragment "PORT-"
```

Per usare una configurazione in un altro percorso, passare `-ConfigPath`. Per eseguire i test con risposte API simulate:

```powershell
.\tests\GLPI.Inventory.Tests.ps1
```

Le prove simulate coprono risultati singoli e multipli, formati degli ID, paginazione e chiusura della sessione su errore. La prova del 13 ottobre 2026 sul GLPI aziendale ha restituito 528 record con ID distinti e validi, 527 nomi distinti e cinque stati. Un nome ha due registrazioni con seriali diversi; questi record resteranno distinti nel dettaglio. Tutti i risultati della prova hanno EntityId 0.

Il [progetto Computer Explorer](docs/Computer-Explorer.md) descrive la futura ricerca aggregata AD / Entra / Intune / GLPI e le colonne richieste.

## Prova della ricerca AD parziale

`Test-AdLookup.ps1` cerca il frammento in nome, nome DNS e sAMAccountName sui DC configurati. Mostra l'esito di ogni DC, le presenze rispetto al totale, i DC verificati e il percorso del contenitore/OU letto da `CanonicalName`.

Usa lo stesso `computer-explorer.config.local.json` del test GLPI:

```powershell
.\Test-AdLookup.ps1 -NameFragment "PORT-" -Verbose
```

`Verde` indica presenza su tutti i DC configurati, `Giallo` una presenza parziale dopo aver verificato tutti i DC e `Grigio` un'interrogazione incompleta. I colori sono per ora esposti come testo nel test; verranno applicati alla griglia della console.

GUID o percorsi diversi fra DC vengono segnalati. Un DC che restituisce un errore non viene contato come verificato. Il test effettua soltanto letture AD.

Per i test con risposte AD simulate:

```powershell
.\tests\AD.Lookup.Tests.ps1
```

Questi test coprono presenza su tutti o alcuni DC, DC indisponibile, nessun risultato, nomi con maiuscole diverse, GUID e percorsi differenti, caratteri escaped e dati non validi. La prova sui DC aziendali è il prossimo passaggio.

## Sviluppi previsti

Ricerca per frammento del nome, vista aggregata delle presenze AD/Entra/Intune e integrazione GLPI per presenza e stato inventariale.

