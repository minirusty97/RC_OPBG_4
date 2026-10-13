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

## Sviluppi previsti

Ricerca per frammento del nome, vista aggregata delle presenze AD/Entra/Intune e integrazione GLPI per presenza e stato inventariale.
