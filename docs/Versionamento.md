# Versionamento di Assistente IT

Il prodotto usa `MAJOR.MINOR.PATCH` (per esempio `1.1.0`). L'unica versione
installabile e aggiornata via OTA e quella di `assistente-it.json`. I moduli
viaggiano nello stesso pacchetto; non richiedono numeri indipendenti.

| Incremento | Quando | Esempio |
| --- | --- | --- |
| PATCH | Correzione, diagnostica, manutenzione o ritocco grafico compatibile | `1.1.0` → `1.1.1` |
| MINOR | Nuovo modulo o nuova funzione compatibile con dati e impostazioni esistenti | `1.1.4` → `1.2.0` |
| MAJOR | Cambiamento incompatibile di configurazione, dati o funzionamento che richiede una migrazione esplicita | `1.4.8` → `2.0.0` |

L'introduzione di Hybrid Join e Gestione Ring porta `1.0.24` a **`1.1.0`**.
Con MINOR si azzera PATCH; con MAJOR si azzerano MINOR e PATCH. I numeri non
si incrementano per singolo commit, tentativo o chat. Una release comprende
tutte le modifiche testate che vengono pubblicate insieme e usa l'incremento
piu alto necessario. Una versione pubblicata non si riutilizza o sostituisce.

Prima del merge aggiornare manifest, `docs/releases/<versione>.md` e stato del
progetto. Installer, eseguibile e feed derivano dalla stessa versione. Su un
ramo di modulo ancora in sviluppo il numero e una proposta: chi integra la
release verifica il numero libero su main, evitando collisioni tra chat.

Non cambiare versione durante una ricerca o una proposta senza modifiche al
prodotto. I controlli CI lavorano sul commit preciso; il tag stabile viene
pubblicato soltanto dopo Windows, installer e controlli del ciclo OTA.
