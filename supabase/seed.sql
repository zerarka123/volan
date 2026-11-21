-- Wilayas d'Algérie (69 depuis la loi n° 26-06 du 4 avril 2026).
-- Les codes 59 à 69 suivent l'ordre de la liste publiée au Journal officiel :
-- à vérifier contre l'arrêté d'immatriculation des véhicules avant la mise en production.
insert into wilayas (code, name_ar, name_fr) values
(1,'أدرار','Adrar'),(2,'الشلف','Chlef'),(3,'الأغواط','Laghouat'),(4,'أم البواقي','Oum El Bouaghi'),
(5,'باتنة','Batna'),(6,'بجاية','Béjaïa'),(7,'بسكرة','Biskra'),(8,'بشار','Béchar'),
(9,'البليدة','Blida'),(10,'البويرة','Bouira'),(11,'تمنراست','Tamanrasset'),(12,'تبسة','Tébessa'),
(13,'تلمسان','Tlemcen'),(14,'تيارت','Tiaret'),(15,'تيزي وزو','Tizi Ouzou'),(16,'الجزائر','Alger'),
(17,'الجلفة','Djelfa'),(18,'جيجل','Jijel'),(19,'سطيف','Sétif'),(20,'سعيدة','Saïda'),
(21,'سكيكدة','Skikda'),(22,'سيدي بلعباس','Sidi Bel Abbès'),(23,'عنابة','Annaba'),(24,'قالمة','Guelma'),
(25,'قسنطينة','Constantine'),(26,'المدية','Médéa'),(27,'مستغانم','Mostaganem'),(28,'المسيلة','M''Sila'),
(29,'معسكر','Mascara'),(30,'ورقلة','Ouargla'),(31,'وهران','Oran'),(32,'البيض','El Bayadh'),
(33,'إليزي','Illizi'),(34,'برج بوعريريج','Bordj Bou Arréridj'),(35,'بومرداس','Boumerdès'),(36,'الطارف','El Tarf'),
(37,'تندوف','Tindouf'),(38,'تيسمسيلت','Tissemsilt'),(39,'الوادي','El Oued'),(40,'خنشلة','Khenchela'),
(41,'سوق أهراس','Souk Ahras'),(42,'تيبازة','Tipaza'),(43,'ميلة','Mila'),(44,'عين الدفلى','Aïn Defla'),
(45,'النعامة','Naâma'),(46,'عين تموشنت','Aïn Témouchent'),(47,'غرداية','Ghardaïa'),(48,'غليزان','Relizane'),
(49,'تيميمون','Timimoun'),(50,'برج باجي مختار','Bordj Badji Mokhtar'),(51,'أولاد جلال','Ouled Djellal'),(52,'بني عباس','Béni Abbès'),
(53,'عين صالح','In Salah'),(54,'عين قزام','In Guezzam'),(55,'تقرت','Touggourt'),(56,'جانت','Djanet'),
(57,'المغير','El M''Ghair'),(58,'المنيعة','El Meniaa'),
(59,'آفلو','Aflou'),(60,'بريكة','Barika'),(61,'القنطرة','El Kantara'),(62,'بئر العاتر','Bir El Ater'),
(63,'العريشة','El Aricha'),(64,'قصر الشلالة','Ksar Chellala'),(65,'عين وسارة','Aïn Oussara'),(66,'مسعد','Messaad'),
(67,'قصر البخاري','Ksar El Boukhari'),(68,'بوسعادة','Bou Saâda'),(69,'الأبيض سيدي الشيخ','El Abiodh Sidi Cheikh')
on conflict (code) do update set name_ar = excluded.name_ar, name_fr = excluded.name_fr;
