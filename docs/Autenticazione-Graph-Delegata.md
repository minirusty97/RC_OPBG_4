# Microsoft Graph: app dedicata con accesso delegato

Disponibile da Assistente IT 1.0.17 in **Impostazioni > Microsoft Graph > Accesso delegato (app dedicata)**. Ogni tecnico accede con il proprio account Microsoft aziendale; l'app usa i permessi delegati consentiti insieme ai diritti effettivi del tecnico su Entra e Intune. Si applicano i criteri di accesso del tenant, compresa MFA quando richiesta.

Questo flusso desktop usa un client pubblico: servono **Tenant ID** e **Client ID**, senza certificato, chiave privata o client secret. Da 1.0.18 la modalita applicativa con certificato e rimossa. Accesso e verifica precedono l'apertura del modulo: vedere [Accesso iniziale](Accesso-Iniziale.md).

## Configurazione per il sistemista

1. In **Entra ID > App registrations**, creare o configurare l'app dedicata, con account del solo tenant aziendale.
2. In **Authentication**, configurare la piattaforma **Mobile and desktop applications / Public client** e i redirect URI:
   - `http://localhost`, per il login tramite browser;
   - `ms-appx-web://Microsoft.AAD.BrokerPlugin/<CLIENT_ID>`, sostituendo `<CLIENT_ID>` con l'Application ID, per il broker Windows WAM usato dal modulo Graph incluso.
3. In **API permissions > Microsoft Graph**, scegliere **Delegated permissions / Autorizzazioni delegate**, aggiungere gli ambiti necessari dalla tabella seguente e concedere il **consenso amministratore**.
4. Nell'**Enterprise application** corrispondente impostare **Assignment required? = Yes** e assegnare gli utenti o gruppi di tecnici autorizzati a usare l'app. Le assegnazioni di gruppo dipendono dalle funzionalita/licenze del tenant; e possibile assegnare direttamente gli utenti.
5. Assegnare separatamente i ruoli Entra e Intune necessari ai tecnici. Il consenso amministratore all'app non assegna quei ruoli agli utenti.
6. Fornire al tecnico Directory (Tenant) ID e Application (Client) ID. Non occorre attendere il certificato.

Per una distribuzione che deve rispettare esclusivamente i diritti dell'operatore, configurare questa autenticazione delegata e rimuovere gli eventuali permessi **Applicazione** non piu necessari dopo aver verificato che non servano ad altri processi. Non distribuire la chiave privata della modalita applicativa per questo utilizzo.

## Ambiti delegati richiesti

| Funzione | Permesso delegato Graph | Controllo sull'utente |
|---|---|---|
| Ricerca dispositivi Entra | `Device.Read.All` | Diritti di lettura dispositivi Entra |
| Ricerca dispositivi Intune | `DeviceManagementManagedDevices.Read.All` | Ruolo Intune con accesso ai dispositivi interessati |
| Lettura password BitLocker cloud | `BitlockerKey.Read.All` | Proprietario del dispositivo o ruolo Entra supportato per la lettura chiavi |
| Eliminazione registrazioni Entra | `Directory.AccessAsUser.All` | Per esempio Cloud Device Administrator, Intune Administrator o Windows 365 Administrator, oppure ruolo personalizzato compatibile |
| Eliminazione dispositivi Intune | `DeviceManagementManagedDevices.ReadWrite.All` | Ruolo Intune con il diritto di eliminare i dispositivi interessati |

Per tutte le funzioni sono necessari tutti e cinque gli ambiti. Da 1.0.18 il wrapper accede con `.default` e mostra prima dell'apertura del modulo gli ambiti gia autorizzati. Le funzioni prive di consenso non richiedono permessi aggiuntivi durante l'uso. Se il sistemista non autorizza `Directory.AccessAsUser.All`, l'eliminazione Entra viene segnalata come non disponibile; ricerca, chiavi e Intune rimangono utilizzabili con i rispettivi consensi e diritti.

`Directory.AccessAsUser.All` e l'ambito delegato richiesto da Microsoft per `DELETE /devices`: non viene sostituito con `Device.ReadWrite.All`, che la documentazione elenca per l'accesso applicativo. E un ambito ampio: il sistemista deve valutarlo e limitarne l'utilizzo con assegnazioni, ruoli e criteri del tenant. Con l'app dedicata il wrapper non lo aggiunge alla richiesta se non e tra i consensi gia concessi.

`BitlockerKey.ReadBasic.All` permette di leggere metadati, non il valore della password. Tra i ruoli Entra supportati per le chiavi ci sono Helpdesk Administrator e Cloud Device Administrator: un ruolo che consente di leggerle puo anche consentire altre operazioni. La separazione dei compiti va verificata sui diritti effettivi; assegnare lo stesso ruolo amministrativo ampio a tutti annullerebbe quella separazione. La lettura del valore genera l'audit Microsoft previsto.

## Gestire chi puo fare cosa

Il sistemista configura utenti/gruppi e ruoli nei sistemi di origine, per esempio:

| Profilo desiderato | Diritti da assegnare e verificare |
|---|---|
| Consultazione inventario | Lettura dispositivi Entra e Intune, senza diritti di eliminazione o lettura password BitLocker |
| Recupero chiavi | Lettura inventario e ruolo Entra compatibile per BitLocker; verificare gli altri diritti inclusi nel ruolo scelto |
| Ritiro/sostituzione PC | Diritti di eliminazione sulle fonti usate, lettura chiavi per il backup obbligatorio e scrittura delle Note GLPI |

L'assegnazione all'app decide chi puo accedere; i ruoli Entra/Intune e gli ambiti nel token decidono le operazioni consentite. Assistente IT non crea profili locali e non assegna ruoli: il riepilogo iniziale segnala i consensi mancanti e le scelte di eliminazione prive di ambito vengono disabilitate. Le API continuano a verificare i ruoli effettivi, senza usare credenziali applicative alternative.

**AD e GLPI mantengono autorizzazioni proprie.** AD usa l'account Windows e i relativi diritti, GLPI il profilo del token personale configurato. Anche **Leggi archivio** dipende dai diritti sulle Note GLPI, dove le chiavi sono conservate in chiaro. Limitare un ruolo Entra non limita automaticamente l'accesso alle copie gia archiviate in GLPI.

## Attivazione in Assistente IT

1. Aggiornare almeno alla versione 1.0.17 e chiudere i moduli aperti.
2. Aprire **Impostazioni > Microsoft Graph** e selezionare **Accesso delegato (app dedicata)**.
3. Inserire Tenant ID e Client ID e salvare. I controlli del certificato sono stati rimossi.
4. Dal wrapper scegliere **Accesso e apri**: completare il login con l'account del tecnico e controllare il riepilogo prima di aprire Computer Explorer.
5. Verificare il recupero chiavi e le autorizzazioni con account dei diversi profili concordati. Per i profili limitati controllare anche che le operazioni escluse vengano rifiutate. Il backup GLPI obbligatorio continua a precedere ogni eliminazione.

Esempio con identificativi fittizi:

```json
"Graph": {
  "AuthenticationMode": "Delegated",
  "TenantId": "11111111-1111-4111-8111-111111111111",
  "ClientId": "22222222-2222-4222-8222-222222222222"
}
```

Le configurazioni esistenti rimangono nella modalita salvata: l'aggiornamento non attiva automaticamente l'app dedicata. **Accesso utente (app Microsoft)** conserva il flusso precedente; in quella modalita gli ID salvati non selezionano l'app aziendale.

La sessione viene riutilizzata solo se delegata, nello stesso tenant e con lo stesso Client ID, ambiente Global e cache personale `CurrentUser`. Nel wrapper una sessione precedente viene sostituita dall'accesso configurato; durante le funzioni una sessione differente viene rifiutata senza login o cambio di identita. Un login fallito o annullato non apre il modulo. Gli ambiti mancanti vengono segnalati nel riepilogo; le funzioni interessate non richiedono altri consensi e non usano l'app Microsoft come ripiego.

## Verifiche ed errori

- Errore di redirect: controllare entrambi i redirect URI della piattaforma desktop/pubblica.
- Utente non assegnato: verificare l'Enterprise application e le sue assegnazioni.
- Consenso richiesto o mancante: verificare gli ambiti **Delegati** e il consenso amministratore; non aggiungere permessi Applicazione per aggirare l'errore.
- HTTP 403: verificare anche ruoli, eventuali ambiti amministrativi e assegnazioni Intune dell'account utilizzato.
- Accesso/chiavi AD o Note GLPI: verificare i diritti di quei sistemi separatamente.

Le prove automatiche coprono sessioni simulate, ambiti, identita, annullamento e salvataggio nella GUI Windows. Non accedono al tenant aziendale: la prova reale richiede la registrazione autorizzata dal sistemista e gli account con i ruoli concordati.

## Riferimenti Microsoft

- [Graph PowerShell: app personalizzata per accesso delegato, redirect e assegnazioni](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands#use-delegated-access-with-a-custom-application-for-microsoft-graph-powershell)
- [Lettura dispositivi Entra](https://learn.microsoft.com/en-us/graph/api/device-list)
- [Eliminazione dispositivi Entra: ambiti e ruoli](https://learn.microsoft.com/en-us/graph/api/device-delete)
- [Eliminazione dispositivi Intune](https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-delete)
- [Lettura chiavi BitLocker: ambiti e ruoli](https://learn.microsoft.com/en-us/graph/api/bitlockerrecoverykey-get)
- [Controllo dei ruoli Intune](https://learn.microsoft.com/en-us/graph/api/resources/intune-rbac-conceptual)
