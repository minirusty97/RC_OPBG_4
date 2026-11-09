# Ricerca Computer Explorer dalla 1.3.2

La ricerca AD ordinaria consulta tutti i DC configurati, in sequenza.
Il DC principale parte per primo. In **Impostazioni → Ricerca computer**
si può indicare un DC già configurato con nome completo o nome breve
univoco. Il campo vuoto dà priorità a dc1 o srvdc1, se presenti, e usa il
primo dell'elenco negli altri casi. La copertura di tutti i DC si applica
anche alle configurazioni salvate con la precedente opzione per un solo DC.

Ogni DC riceve un filtro LDAP per frammento su Name, DNSHostName e
sAMAccountName. La griglia riporta la presenza e il numero dei DC
verificati separatamente. Una replica irraggiungibile è non verificabile.

Il confronto Hybrid usa l'ObjectGUID restituito per il nome dal DC
principale. L'ID Entra riportato da Intune viene confrontato quando
corrisponde a una registrazione Hybrid della riga. Un PC presente solo
sulle altre repliche resta visibile e il confronto viene saltato. I dati
già raccolti bastano per questa verifica nella griglia.

La verifica prima dell'eliminazione segue il flusso dedicato e legge di
nuovo gli oggetti sui DC configurati. Il modulo Verifica Hybrid Join usa
il proprio server AD e le proprie OU.

Per le ricerche GLPI, il connettore nativo getMultipleItems legge fino a 20
schede per richiesta. I dettagli gia letti vengono riutilizzati nel successivo
controllo per seriale della stessa ricerca; la ricerca seriale continua a
verificare anche eventuali schede rinominate o duplicate. La cache contiene
solo DTO di inventario, e limitata alla ricerca e alle stesse credenziali e
non riguarda le riletture fresche prima di archivi BitLocker e cancellazioni.
Non sono richiesti plugin GLPI e le Note esistenti restano preservate.

Gli abbinamenti seriali e GUID usano indici per evitare di ripercorrere tutto
l inventario per ogni PC. Gli aggiornamenti del solo avanzamento non
ricalcolano le righe; l arrivo di nuovi dati le ricalcola. I risultati di
servizi indipendenti continuano a comparire progressivamente.

I test sintetici verificano una lettura per DC configurato, l'ordine di
avvio, i casi in cui il DC principale è irraggiungibile o non ha il PC,
e il riuso dei dettagli GLPI nella stessa ricerca. I tempi dei filtri
LDAP dipendono dai dati e dal piano di ricerca del DC. Il confronto dei
tempi su rete aziendale richiede la stessa query, le stesse fonti e la
stessa condizione di cache.

Il ramo `diagnostic/ad-parallelo` aggiunge una
[prova portatile di confronto](Test-AD-Parallelo.md) con lettori
AD isolati, ritentativo sequenziale e tempi per fonte.
