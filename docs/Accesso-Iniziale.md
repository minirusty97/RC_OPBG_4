# Accesso e verifica prima dei moduli

Da Assistente IT 1.0.18 il pulsante **Accesso e apri** avvia il wrapper comune. Prima di mostrare il modulo, il wrapper:

1. Legge la configurazione Graph e i requisiti del modulo dal manifest.
2. Esegue l'accesso utente Microsoft nella modalita configurata.
3. Legge gli ambiti effettivamente restituiti dal token tramite il contesto SDK.
4. Mostra le funzioni con ambito disponibile e quelle prive di consenso.
5. Verifica le letture Entra e Intune con richieste GET limitate a un ID. Non elimina oggetti e non legge password BitLocker.
6. Apre il modulo soltanto dopo la scelta **Apri modulo** o **Apri funzioni disponibili**.

Un errore o un annullamento non apre il modulo. La finestra riporta l'errore senza ripetere automaticamente il login. Durante l'uso, i moduli controllano la sessione e gli ambiti: non chiamano il login e non richiedono nuovi consensi. Una sessione assente o non corrispondente, oppure un ambito mancante, richiede di tornare al wrapper.

## App dedicata

**Accesso delegato (app dedicata)** usa Tenant ID e Client ID configurati con lo scope `https://graph.microsoft.com/.default`. Se esiste almeno un consenso Graph per quell'app e utente, Microsoft restituisce gli ambiti gia concessi. Il wrapper non aggiunge permessi quando si preme un comando e non forza un consenso aggiuntivo. Se nessun consenso esiste, Microsoft puo richiedere l'approvazione iniziale dell'amministratore; il modulo resta chiuso se l'accesso non riesce.

Se `Directory.AccessAsUser.All` non e stato autorizzato, il riepilogo segnala **Eliminazione Entra ID: non disponibile**. La funzione non e stata rimossa: resta disponibile con un accesso che possiede l'ambito e i diritti necessari. Non viene avviato un accesso alternativo all'app Microsoft per aggirare un consenso mancante.

**Accesso utente (app Microsoft)** conserva il metodo precedente. Il wrapper richiede in un unico accesso iniziale gli ambiti dichiarati dal modulo, compreso quello di eliminazione Entra. I consensi dell'app Microsoft e dell'app dedicata restano separati.

Gli ambiti presenti non dimostrano da soli tutti i diritti dell'utente. Le prove iniziali verificano le letture; le eliminazioni dipendono dai ruoli Entra/Intune e gli errori delle API vengono riportati senza riaprire il consenso. AD usa l'account Windows e GLPI i token configurati, con le rispettive autorizzazioni.

## Processi e sessione

Il menu principale avvia ogni modulo in un processo separato per conservarne isolamento e ciclo di vita. L'accesso avviene in **AssistenteIT/Invoke-Module.ps1**, nello stesso processo che poi ospita il modulo. La finestra di verifica usa un runspace; il contesto statico del Graph SDK resta disponibile ai runspace del modulo nello stesso processo. Non si passano token su riga di comando o tramite file temporanei.

L'accesso puo essere riutilizzato dalla cache personale Microsoft; ogni apertura verifica comunque configurazione e autorizzazioni. Modificare tenant o app richiede di chiudere e riaprire il modulo tramite il wrapper. I programmi gia aperti non cambiano identita in seguito a un salvataggio delle impostazioni.

## Requisiti dei moduli futuri

Il manifest `assistente-it.json` puo dichiarare `GraphPermissions` per ogni modulo:

```json
"UsesGraphAccess": true,
"GraphPermissions": [
  {
    "Id": "entra-read",
    "Name": "Ricerca Entra ID",
    "AnyOf": ["Device.Read.All", "Directory.Read.All"]
  }
]
```

`AnyOf` elenca ambiti alternativi sufficienti. Nel login con app Microsoft il wrapper combina gli ambiti dei requisiti ed elimina quelli ridondanti gia coperti da un'alternativa piu ampia; l'app dedicata usa sempre `.default` e i consensi gia presenti. ID, nomi e ambiti vengono validati dal lettore del manifest.

Con `UsesGraphAccess` il wrapper passa il riepilogo al parametro `GraphAccess` del modulo. I moduli senza `GraphPermissions` non avviano Graph. Il wrapper resta generico e non dipende da Computer Explorer.

## Autenticazione con certificato

La modalita applicativa con certificato e stata rimossa, insieme a campi e codice relativi. Le configurazioni di accesso utente restano valide; gli eventuali vecchi campi del certificato vengono ignorati e rimossi al salvataggio. Una configurazione ancora impostata su `Certificate` deve essere corretta esplicitamente da Impostazioni: il programma non cambia automaticamente identita. I certificati nello store Windows non vengono modificati o cancellati.

## Collaudo

Le prove automatiche usano risposte simulate e finestre Windows reali: coprono accesso iniziale, riepilogo parziale, letture, annullamento, mancato consenso, riuso della sessione e assenza di nuove richieste nelle funzioni. Il collaudo aziendale rimane necessario per app, consensi, ruoli e criteri di accesso del tenant.

Riferimenti: [scope .default e consensi](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope), [autenticazione Graph PowerShell](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands).
