# Accesso comune e autorizzazioni dei moduli

Da Assistente IT 1.0.19 **Accesso** e un pulsante separato nella barra inferiore, accanto a Impostazioni, Cartella dati e Cerca aggiornamenti. Le schede dei moduli mostrano **Apri modulo**, inizialmente disabilitato.

## Flusso

1. Configurare tenant/app in Impostazioni, se necessario.
2. Premere **Accesso** e completare il login Microsoft.
3. Controllare il riepilogo dei permessi e confermare l'accesso. Nessun modulo viene aperto automaticamente.
4. Il wrapper abilita ciascun modulo per il quale sono soddisfatti i requisiti di lettura, indicando **Sola lettura** o **Lettura e scrittura secondo i permessi verificati**.
5. Premere **Apri modulo** sulla scheda desiderata. Il modulo usa la sessione gia verificata, senza un secondo login o nuovi consensi.

I moduli sono ospitati in runspace STA separati nello stesso processo, cosi possono condividere il contesto statico del Graph SDK senza passare token su riga di comando o tramite file. Chiudere i moduli prima di cambiare accesso/impostazioni, aggiornare o uscire dal wrapper. Questa scelta mantiene la sessione coerente e non interrompe operazioni attive.

## Permessi e modalita

Il manifest di ogni modulo dichiara `GraphPermissions`, `ReadPermissionIds` e `WritePermissionIds`. Basta un requisito di lettura disponibile tra quelli dichiarati per abilitare il modulo; le singole fonti/funzioni mantengono i loro controlli specifici. Senza un requisito di scrittura disponibile il modulo si apre in sola lettura: eliminazioni e archiviazioni GLPI sono disabilitate e rifiutate anche dai comandi di scrittura.

Esempio dei riferimenti ai requisiti dichiarati in `GraphPermissions`:

```json
"ReadPermissionIds": ["entra-read", "intune-read"],
"WritePermissionIds": ["entra-remove", "intune-remove"]
```

Gli ambiti OAuth sono concessi all'app: non descrivono da soli tutti i diritti di ogni collega. I ruoli Entra/Intune e le autorizzazioni effettive su AD/GLPI restano il controllo del servizio. La verifica iniziale esegue soltanto GET limitate su Entra e Intune, senza provare cancellazioni o leggere password BitLocker.

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

Riferimenti: [AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/appids), [scope .default](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope), [appartenenze dell'utente](https://learn.microsoft.com/en-us/graph/api/user-list-transitivememberof).
