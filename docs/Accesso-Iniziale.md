# Accesso comune e autorizzazioni dei moduli

Da Assistente IT 1.0.19 **Accesso** e un pulsante separato nella barra inferiore, accanto a Impostazioni, Cartella dati e Cerca aggiornamenti. Le schede dei moduli mostrano **Apri modulo**, inizialmente disabilitato.

## Flusso

1. Configurare tenant/app in Impostazioni, se necessario.
2. Premere **Accesso** e completare il login Microsoft.
3. Controllare il riepilogo dei permessi e confermare l'accesso. Nessun modulo viene aperto automaticamente.
4. Il wrapper abilita ciascun modulo per il quale sono soddisfatti i requisiti di lettura, indicando **Sola lettura** o **Lettura e scrittura (ambiti concessi)**.
5. Premere **Apri modulo** sulla scheda desiderata. Il modulo usa la sessione gia verificata, senza un secondo login o nuovi consensi.

I moduli sono ospitati in runspace STA separati nello stesso processo, cosi possono condividere il contesto statico del Graph SDK senza passare token su riga di comando o tramite file. Chiudere i moduli prima di cambiare accesso/impostazioni, aggiornare o uscire dal wrapper. Questa scelta mantiene la sessione coerente e non interrompe operazioni attive.

## Permessi e modalita

Il manifest di ogni modulo dichiara `GraphPermissions`, `ReadPermissionIds` e `WritePermissionIds`. Basta un requisito di lettura disponibile tra quelli dichiarati per abilitare il modulo; le singole fonti/funzioni mantengono i loro controlli specifici. Senza un requisito di scrittura disponibile il modulo si apre in sola lettura: eliminazioni e archiviazioni GLPI sono disabilitate e rifiutate anche dai comandi di scrittura.

Esempio dei riferimenti ai requisiti dichiarati in `GraphPermissions`:

```json
"ReadPermissionIds": ["entra-read", "intune-read"],
"WritePermissionIds": ["entra-remove", "intune-remove"]
```

Gli ambiti OAuth sono concessi all'app: non descrivono da soli tutti i diritti di ogni collega. I ruoli Entra/Intune e le autorizzazioni effettive su AD/GLPI restano il controllo del servizio. Da 1.0.20 il riepilogo distingue l'ambito concesso dalla verifica effettivamente eseguita:

| Funzione | Test iniziale | Esito positivo |
| --- | --- | --- |
| Ricerca Entra / Intune | GET di lettura limitata | Verificata, nei limiti degli oggetti accessibili all'utente |
| Password BitLocker | Una pagina di `GET /informationProtection/bitlocker/recoveryKeys`, senza proprieta `key` | Parziale: accesso all'elenco metadati; lettura password non verificata |
| Eliminazione Entra / Intune | Controllo ambito e prerequisiti di lettura; nessuna DELETE | Non verificabile senza eseguire l'operazione |

Le richieste BitLocker includono lo User-Agent richiesto dalla documentazione, non usano `$top`, non seguono le pagine successive e non interrogano la singola chiave. Un elenco vuoto conferma soltanto che la richiesta e stata accettata. Un errore del servizio mantiene separati `ScopeGranted` e `Available` e mostra la funzione come non disponibile.

L'accesso ai metadati non dimostra quello alla password: Entra prevede anche il diritto personalizzato `microsoft.directory/bitlockerKeys/metadata/read`, distinto da `microsoft.directory/bitlockerKeys/key/read`, e puo limitare i diritti al singolo dispositivo o unita amministrativa. Il test non promette di provare il recupero effettivo.

Le API di cancellazione non espongono una simulazione documentata che verifichi tutti i diritti senza cancellare. `-WhatIf` interrompe l'operazione nel client, quindi non prova l'autorizzazione Microsoft. Non vengono inviate DELETE di prova, nemmeno verso identificativi inesistenti, e non vengono richiesti nuovi consensi per analizzare i ruoli.

Solo le letture realmente eseguite sono verdi; verifiche parziali o non eseguibili sono gialle. Il successivo controllo del servizio rimane determinante.

## Gruppi facoltativi per modulo

Per attribuire accessi diversi ai colleghi anche quando l'app ha gli stessi ambiti, un modulo puo dichiarare gruppi Entra separati. Identificativi fittizi:

```json
"ReadGroupIds": ["33333333-3333-4333-8333-333333333333"],
"WriteGroupIds": ["44444444-4444-4444-8444-444444444444"]
```

- Membro del gruppo lettori: sola lettura, anche se il token dell'app contiene ambiti di scrittura.
- Membro del gruppo operatori: scrittura soltanto se sono disponibili anche i requisiti Graph richiesti.
- Non assegnato: modulo disabilitato.
- Appartenenze non verificabili: modulo disabilitato.

Un operatore puo aprire il modulo senza essere anche nel gruppo lettori. Se e configurato soltanto un gruppo lettori, nessuno riceve accesso in scrittura tramite questa regola. Senza gruppi configurati si applicano i soli requisiti di ambito dichiarati. I gruppi non vengono creati ne assegnati dall'app: il sistemista deve concordare gli accessi e mantenere coerenti le autorizzazioni dei servizi.

Le appartenenze dell'utente autenticato vengono lette con `GET /me/transitiveMemberOf?$select=id`, comprese quelle transitive. Serve il consenso `User.Read` o un ambito compatibile; non si richiedono automaticamente autorizzazioni Directory piu ampie. La verifica gruppi viene eseguita soltanto quando almeno un modulo configura una regola di gruppo. La configurazione attuale di Computer Explorer non contiene gruppi aziendali inventati o preassegnati.

## Modalita di autenticazione

**Accesso delegato (app dedicata)** usa Tenant ID, Client ID e `https://graph.microsoft.com/.default`. Se esiste gia un consenso Graph per quell'app e utente, Microsoft restituisce gli ambiti concessi. Non si aggiungono consensi durante l'uso dei moduli. Se nessun consenso esiste, Microsoft puo richiedere l'approvazione iniziale dell'amministratore; un errore o un annullamento mantiene i moduli disabilitati.

**Accesso utente (app Microsoft)** mantiene il metodo precedente e richiede gli ambiti del catalogo nel solo accesso iniziale, eliminando le richieste ridondanti quando un ambito piu ampio copre gia un requisito. Non si passa automaticamente da un'app all'altra per aggirare un consenso mancante.

La cancellazione Entra resta supportata con `Directory.AccessAsUser.All` e i relativi diritti. Se il consenso manca, la scelta Entra e indisponibile; gli altri accessi autorizzati rimangono utilizzabili. La modalita con certificato e stata rimossa in 1.0.18. Eventuali certificati nello store Windows non vengono modificati.

## Finestra e aggiornamenti

Finestre e collegamenti usano l'identita Windows **AssistenteIT.Desktop** e l'icona del programma. PowerShell resta il motore interno; il launcher non e stato trasformato in un nuovo host eseguibile. Lo stile Windows viene inizializzato prima delle finestre.

**Cerca aggiornamenti** avvia il controllo. Quando una versione e disponibile compare **Installa aggiornamento**. L'installazione conserva configurazione e credenziali personali e richiede la chiusura dei moduli.

Gli errori della ricerca chiavi distinguono ricerca Intune, Azure AD Device ID, elenco metadati, lettura password e risposta non valida. Quando disponibili mostrano stato HTTP, codice Graph e request-id; non riportano corpi di risposta, token o password. Un HTTP 400 non viene presentato come prova di un ruolo mancante.

Riferimenti per i controlli: [elenco metadati BitLocker](https://learn.microsoft.com/en-us/graph/api/bitlocker-list-recoverykeys), [permessi distinti per metadati e password](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/custom-device-permissions), [cancellazione Entra](https://learn.microsoft.com/en-us/graph/api/device-delete), [WhatIf nel cmdlet](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.identity.directorymanagement/remove-mgdevice).

Riferimenti: [AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/appids), [scope .default](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope), [appartenenze dell'utente](https://learn.microsoft.com/en-us/graph/api/user-list-transitivememberof).
