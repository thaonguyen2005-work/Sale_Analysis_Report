--- 1: Create a table containing the dataset and convert the data types appropriately for the fields.
ALTER TABLE sales_dataset_rfm_prj
ALTER COLUMN ordernumber TYPE numeric USING (TRIM(ordernumber):: numeric)
  
ALTER TABLE sales_dataset_rfm_prj
ALTER COLUMN quantityordered TYPE numeric USING (TRIM(quantityordered):: numeric)
  
ALTER TABLE sales_dataset_rfm_prj
ALTER COLUMN priceeach TYPE numeric USING (TRIM(priceeach):: numeric)
  
ALTER TABLE sales_dataset_rfm_prj
ALTER COLUMN orderlinenumber TYPE numeric USING (TRIM(orderlinenumber):: numeric)

ALTER TABLE sales_dataset_rfm_prj
ALTER COLUMN sales TYPE float USING (TRIM(sales):: float)

SET datestyle = 'iso,mdy';  
ALTER TABLE sales_dataset_rfm_prj
ALTER COLUMN orderdate TYPE date USING (TRIM(orderdate):: date)

ALTER TABLE sales_dataset_rfm_prj
ALTER COLUMN msrp TYPE numeric USING (TRIM(msrp):: numeric)

--- 2: Clean the data.
--- 2.1: Check NULL/BLANK ('') in the fields: ORDERNUMBER, QUANTITYORDERED, PRICEEACH, ORDERLINENUMBER, SALES, ORDERDATE.
SELECT *
FROM sales_dataset_rfm_prj
WHERE 
    ORDERNUMBER IS NULL OR
    QUANTITYORDERED IS NULL OR
    PRICEEACH IS NULL OR
    ORDERLINENUMBER IS NULL OR
    SALES IS NULL OR
    ORDERDATE IS NULL;

--- 2.2: Add the columns CONTACTLASTNAME and CONTACTFIRSTNAME, which are split from CONTACTFULLNAME.
ALTER TABLE sales_dataset_rfm_prj
ADD COLUMN CONTACTLASTNAME VARCHAR(255),
ADD COLUMN CONTACTFIRSTNAME VARCHAR(255);

UPDATE sales_dataset_rfm_prj
SET CONTACTLASTNAME = INITCAP(SUBSTRING(CONTACTFULLNAME FROM POSITION('-' IN CONTACTFULLNAME) + 1)),
    CONTACTFIRSTNAME = INITCAP(SUBSTRING(CONTACTFULLNAME FROM 1 FOR POSITION('-' IN CONTACTFULLNAME) - 1))
WHERE CONTACTFULLNAME IS NOT NULL AND POSITION('-' IN CONTACTFULLNAME) > 0;
Hoặc 
UPDATE sales_dataset_rfm_prj
SET CONTACTLASTNAME = SPLIT_PART(CONTACTFULLNAME, ' ', 2),
    CONTACTFIRSTNAME = SPLIT_PART(CONTACTFULLNAME, ' ', 1);

--- 2.3: Add the columns QTR_ID, MONTH_ID, and YEAR_ID, which represent the quarter, month, and year extracted from ORDERDATE.
ALTER TABLE sales_dataset_rfm_prj
ADD COLUMN QTR_ID INT,
ADD COLUMN MONTH_ID INT,
ADD COLUMN YEAR_ID INT;

UPDATE sales_dataset_rfm_prj
SET QTR_ID = EXTRACT(QUARTER FROM ORDERDATE),
    MONTH_ID = EXTRACT(MONTH FROM ORDERDATE),
    YEAR_ID = EXTRACT(YEAR FROM ORDERDATE);

---2.4: Find outliers (if any) for the column QUANTITYORDERED
SELECT * FROM  sales_dataset_rfm_prj

--- Find outliers using IQR/boxplot
with Twt_min_max_values AS(
SELECT Q1 - 1.5*IQR AS min_value, 
Q3 + 1.5*IQR AS max_value FROM
(percentile_cont (0.25) within (ORDER by QUANTITYORDERED) AS Q1, 
percentile_cont (0.75) within (ORDER by QUANTITYORDERED) AS Q3,
percentile_cont (0.75) within (ORDER by QUANTITYORDERED)-percentile_cont (0.25) within (ORDER by QUANTITYORDERED)AS IQR
FROM  sales_dataset_rfm_prj) AS a)

--- Identify outliers:  
SELECT * FROM sales_dataset_rfm_prj
WHERE QUANTITYORDERED< (SELECT min_value FROM Twt_min_max_values )
or QUANTITYORDERED> (SELECT max_value FROM Twt_min_max_values )
--- Usinf Z-score to find outliers:
SELECT avg(QUANTITYORDERED),
stddev(QUANTITYORDERED)
FROM sales_dataset_rfm_prj

with cte as
(SELECT orderdate,QUANTITYORDERED,(avg(QUANTITYORDERED) FROM sales_dataset_rfm_prj) AS avg,
(stddev(QUANTITYORDERED) FROM sales_dataset_rfm_prj) AS stddev
FROM sales_dataset_rfm_prj)
,twt_outliner AS(
SELECT orderdate,QUANTITYORDERED,(QUANTITYORDERED-avg)/stddev AS z_score
from cte 
where ABS ((QUANTITYORDERED-avg)/stddev)>2)

  --- Handle the outlier values using two methods: either update the outliers with the average values or remove them from the dataset.
UPDATE sales_dataset_rfm_prj
SET QUANTITYORDERED=(avg(QUANTITYORDERED) FROM sales_dataset_rfm_prj)
WHERE QUANTITYORDERED IN(SELECT QUANTITYORDERED FROM twt_outliner);

DELETE FROM sales_dataset_rfm_prj
WHERE QUANTITYORDERED IN(SELECT QUANTITYORDERED FROM twt_outliner);

--- 3: Save the cleaned data into a new table named SALES_DATASET_RFM_PRJ_CLEAN
CREATE TABLE SALES_DATASET_RFM_PRJ_CLEAN AS
SELECT *
FROM sales_dataset_rfm_prj
WHERE 
    ORDERNUMBER IS NOT NULL AND
    QUANTITYORDERED IS NOT NULL AND
    PRICEEACH IS NOT NULL AND
    ORDERLINENUMBER IS NOT NULL AND
    SALES IS NOT NULL AND
    ORDERDATE IS NOT NULL;

--- 4: Analyze the dataset to derive insights

--- Revenue by Product Line, Year, and Deal Size?
select productline,YEAR_ID, DEALSIZE, sum(sales) as REVENUE from public.sales_dataset_rfm_prj
group by productline,YEAR_ID, DEALSIZE

--- What is the best-selling month each year?
select year_id,month_ID,ORDER_NUMBER from
(select year_id,
 	month_ID, 
 	sum(sales) as REVENUE,count(ordernumber) as ORDER_NUMBER, 
 	rank() over(partition by year_id order by sum(sales),count(ordernumber))
 from public.sales_dataset_rfm_prj
group by year_id,month_ID) as t
where rank =1

--- What product line sells the most in November?
select productline,month_ID, DEALSIZE, sum(sales) as REVENUE,count(ordernumber) as ORDER_NUMBER from public.sales_dataset_rfm_prj
where month_ID =11
group by productline,month_ID, DEALSIZE
order by sum(sales) desc , count(ordernumber) desc limit 1
-- Result: Classic Cars

--- What is the best-selling product in the UK each year?
select * from 
(select YEAR_ID, PRODUCTLINE,sum(sales) as REVENUE, RANK() over(partition by YEAR_ID order by sum(sales ) desc) from public.sales_dataset_rfm_prj
where country ='UK'
group by YEAR_ID, PRODUCTLINE) as t
where rank = 1

--- Who is the best customer? Analyze based on RFM.
-- Extract R-F-M
with cte as 
(select 
contactfullname,postalcode,
current_date - max(orderdate) as R,
count(distinct ordernumber) as F,
sum(sales) as M 
from public.sales_dataset_rfm_prj
group by contactfullname,postalcode),
-- R-F-M Classification
cte1 as 
(select contactfullname,postalcode,
ntile(5) over(order by R desc) as
R_score,
ntile(5) over(order by F ) as F_score,
ntile(5) over(order by M ) as M_score
from cte),
cte2 as 
(select contactfullname,postalcode,
 cast(R_score as varchar)|| cast(R_score as varchar)||cast(R_score as varchar)
 as rfm_score from cte1)
 select contactfullname,postalcode, rfm_score from cte2 as a join public.segment_score as b 
 on a.rfm_score = b.scores
 where segment = 'Champions'
