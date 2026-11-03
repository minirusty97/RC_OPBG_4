# Ricerca Computer Explorer dalla 1.2.0

La consultazione AD ordinaria usa un solo DC: srvDC1, se il suo nome breve
compare nell elenco personale Domain Controller, altrimenti il primo DC
configurato. Non viene inserito un server aziendale nel modello pubblico.

In **Impostazioni → Ricerca computer** si puo scegliere un altro DC gia
configurato, usando nome completo o nome breve univoco. Vuoto mantiene la
scelta automatica. **Diagnostica: consulta tutti i DC configurati** ripristina
la lettura su tutti i DC quando serve confrontare le repliche; richiede piu
tempo. Un DC non raggiungibile resta un errore, non un assenza confermata e
non avvia tentativi nascosti sugli altri server. La griglia e i dettagli
riportano soltanto il numero di DC effettivamente consultati (normalmente 1/1).

La scelta vale anche per l arricchimento Hybrid tramite GUID in Computer
Explorer. Il modulo Verifica Hybrid Join conserva il proprio server AD e
le proprie OU. Il recupero BitLocker AD e la preparazione/cancellazione dei
computer mantengono l elenco completo dei DC e i controlli precedenti: una
lettura verde su 1/1 non certifica la replica su tutti i DC.

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

I test sintetici verificano una richiesta AD invece di tutte quelle dei DC
configurati, 3 richieste dettagli per 45 schede GLPI e nessuna rilettura dei
loro dettagli durante l arricchimento seriale. Non costituiscono una misura
del tempo su rete e dati aziendali: confrontare la ricerca Port- dopo
l aggiornamento usando le medesime fonti e condizioni di cache.
