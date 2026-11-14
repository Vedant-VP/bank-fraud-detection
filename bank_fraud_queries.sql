-- bank fraud detection (oracle 10g, sql*plus)
-- run the sections in order

-- user
connect / as sysdba
create user bankdb identified by your_password;
grant connect, resource, create view, create procedure, create trigger to bankdb;
connect bankdb/your_password


-- tables
create table branches (
  branch_id   number primary key,
  branch_name varchar2(80) not null,
  city        varchar2(50) not null
);

create table customers (
  customer_id number primary key,
  full_name   varchar2(100) not null,
  email       varchar2(100) unique,
  phone       varchar2(15),
  city        varchar2(50),
  join_date   date default sysdate
);

create table accounts (
  account_id   number primary key,
  customer_id  number not null references customers(customer_id),
  branch_id    number not null references branches(branch_id),
  account_type varchar2(15) check (account_type in ('SAVINGS','CURRENT','SALARY')),
  balance      number(14,2) default 0,
  status       varchar2(10) default 'ACTIVE' check (status in ('ACTIVE','FROZEN','CLOSED')),
  open_date    date default sysdate
);

create table transactions (
  txn_id     number primary key,
  account_id number not null references accounts(account_id),
  txn_type   varchar2(12) check (txn_type in ('DEPOSIT','WITHDRAWAL','TRANSFER','PAYMENT')),
  amount     number(14,2) not null check (amount > 0),
  txn_time   date not null,
  city       varchar2(50),
  channel    varchar2(10) check (channel in ('ATM','UPI','ONLINE','BRANCH','POS'))
);

-- most rules look up by account and time
create index idx_txn_acc_time on transactions(account_id, txn_time);
create index idx_txn_time     on transactions(txn_time);

create table fraud_rules (
  rule_code   varchar2(30) primary key,
  description varchar2(200),
  weight      number(3) not null,
  is_active   char(1) default 'Y'
);

create table fraud_alerts (
  alert_id   number primary key,
  txn_id     number not null references transactions(txn_id),
  account_id number not null,
  risk_score number(3) not null,
  rules_hit  varchar2(200),
  status     varchar2(15) default 'OPEN' check (status in ('OPEN','REVIEW','CONFIRMED','CLEARED')),
  created_at date default sysdate
);


-- sequences + auto id triggers (10g has no identity columns)
create sequence seq_branches;
create sequence seq_customers;
create sequence seq_accounts;
create sequence seq_transactions cache 1000;
create sequence seq_alerts;

create or replace trigger trg_branches_bi
before insert on branches
for each row
begin
  select seq_branches.nextval into :new.branch_id from dual;
end;
/
create or replace trigger trg_customers_bi
before insert on customers
for each row
begin
  select seq_customers.nextval into :new.customer_id from dual;
end;
/
create or replace trigger trg_accounts_bi
before insert on accounts
for each row
begin
  select seq_accounts.nextval into :new.account_id from dual;
end;
/
create or replace trigger trg_transactions_bi
before insert on transactions
for each row
begin
  select seq_transactions.nextval into :new.txn_id from dual;
end;
/
create or replace trigger trg_alerts_bi
before insert on fraud_alerts
for each row
begin
  select seq_alerts.nextval into :new.alert_id from dual;
end;
/


-- rules and weights (alert fires when total weight >= 40)
insert into fraud_rules values ('HIGH_AMOUNT','Amount > 5x account average',40,'Y');
insert into fraud_rules values ('VELOCITY','5+ txns within 10 minutes',40,'Y');
insert into fraud_rules values ('ODD_HOUR','Txn above 50k between 1 AM and 4 AM',20,'Y');
insert into fraud_rules values ('LOCATION_JUMP','Different city within 1 hour',35,'Y');
insert into fraud_rules values ('STRUCTURING','5+ small deposits in a day then big withdrawal',40,'Y');
commit;


-- sample data (random, so it is synthetic)
insert into branches(branch_name, city) values ('Main Branch','Mumbai');
insert into branches(branch_name, city) values ('Central Branch','Delhi');
insert into branches(branch_name, city) values ('Tech Park Branch','Bengaluru');
insert into branches(branch_name, city) values ('Marina Branch','Chennai');
insert into branches(branch_name, city) values ('Lake Branch','Kolkata');

-- 5000 customers
insert into customers(full_name, email, phone, city)
select 'Customer ' || level,
       'cust' || level || '@mail.com',
       '9' || trunc(dbms_random.value(100000000, 999999999)),
       decode(trunc(dbms_random.value(1,6)),1,'Mumbai',2,'Delhi',3,'Bengaluru',4,'Chennai','Kolkata')
from dual connect by level <= 5000;

-- one account per customer
insert into accounts(customer_id, branch_id, account_type, balance, open_date)
select customer_id,
       trunc(dbms_random.value(1,6)),
       decode(trunc(dbms_random.value(1,4)),1,'SAVINGS',2,'CURRENT','SALARY'),
       round(dbms_random.value(5000, 500000), 2),
       sysdate - trunc(dbms_random.value(30, 2000))
from customers;
commit;

-- 500k normal transactions over the last year (5 batches of 100k)
begin
  for i in 1..5 loop
    insert into transactions(account_id, txn_type, amount, txn_time, city, channel)
    select trunc(dbms_random.value(1,5001)),
           decode(trunc(dbms_random.value(1,5)),1,'DEPOSIT',2,'WITHDRAWAL',3,'TRANSFER','PAYMENT'),
           round(dbms_random.value(100, 20000), 2),
           sysdate - dbms_random.value(0, 365),
           decode(trunc(dbms_random.value(1,6)),1,'Mumbai',2,'Delhi',3,'Bengaluru',4,'Chennai','Kolkata'),
           decode(trunc(dbms_random.value(1,6)),1,'ATM',2,'UPI',3,'ONLINE',4,'BRANCH','POS')
    from dual connect by level <= 100000;
    commit;
  end loop;
end;
/

-- planted fraud 1: 400 big online transfers at 2 AM
insert into transactions(account_id, txn_type, amount, txn_time, city, channel)
select trunc(dbms_random.value(1,5001)), 'TRANSFER',
       round(dbms_random.value(150000, 400000), 2),
       trunc(sysdate) - trunc(dbms_random.value(1,300)) + 2/24,
       'Mumbai', 'ONLINE'
from dual connect by level <= 400;

-- planted fraud 2: 6 quick atm withdrawals on accounts 1-50
insert into transactions(account_id, txn_type, amount, txn_time, city, channel)
select a.account_id, 'WITHDRAWAL', 9000 + n.lvl * 100,
       trunc(sysdate) - 10 + 14/24 + n.lvl/1440, 'Delhi', 'ATM'
from (select account_id from accounts where account_id <= 50) a,
     (select level lvl from dual connect by level <= 6) n;
commit;


-- one view per rule
create or replace view v_rule_high_amount as
select t.txn_id, t.account_id, 'HIGH_AMOUNT' as rule_code
from transactions t
join (select account_id, avg(amount) avg_amt from transactions group by account_id) a
  on a.account_id = t.account_id
where t.amount > 5 * a.avg_amt;

-- window of 10 minutes (10/1440 of a day) ending at this txn
create or replace view v_rule_velocity as
select txn_id, account_id, 'VELOCITY' as rule_code
from (
  select txn_id, account_id,
         count(*) over (partition by account_id order by txn_time
                        range between 10/1440 preceding and current row) as cnt
  from transactions
)
where cnt >= 5;

create or replace view v_rule_odd_hour as
select txn_id, account_id, 'ODD_HOUR' as rule_code
from transactions
where to_number(to_char(txn_time,'HH24')) between 1 and 4
  and amount > 50000;

-- compare with the previous txn on the same account
create or replace view v_rule_location_jump as
select txn_id, account_id, 'LOCATION_JUMP' as rule_code
from (
  select txn_id, account_id, city, txn_time,
         lag(city)     over (partition by account_id order by txn_time) as prev_city,
         lag(txn_time) over (partition by account_id order by txn_time) as prev_time
  from transactions
)
where prev_city is not null
  and city <> prev_city
  and txn_time - prev_time < 1/24;

create or replace view v_rule_structuring as
select w.txn_id, w.account_id, 'STRUCTURING' as rule_code
from transactions w
where w.txn_type = 'WITHDRAWAL' and w.amount > 50000
  and (select count(*) from transactions d
       where d.account_id = w.account_id
         and d.txn_type = 'DEPOSIT' and d.amount < 50000
         and d.txn_time between w.txn_time - 1 and w.txn_time) >= 5;

create or replace view v_all_rule_hits as
select * from v_rule_high_amount
union all select * from v_rule_velocity
union all select * from v_rule_odd_hour
union all select * from v_rule_location_jump
union all select * from v_rule_structuring;


-- scan: add up the weights per transaction, alert if >= 40
-- not exists = safe to run again without duplicate alerts
create or replace procedure sp_run_fraud_scan is
begin
  insert into fraud_alerts(txn_id, account_id, risk_score, rules_hit)
  select h.txn_id, h.account_id,
         least(100, sum(r.weight)),
         wm_concat(h.rule_code)
  from v_all_rule_hits h
  join fraud_rules r on r.rule_code = h.rule_code and r.is_active = 'Y'
  where not exists (select 1 from fraud_alerts f where f.txn_id = h.txn_id)
  group by h.txn_id, h.account_id
  having sum(r.weight) >= 40;
  commit;
end;
/

create or replace procedure sp_freeze_account(p_account_id in number) is
begin
  update accounts set status = 'FROZEN' where account_id = p_account_id;
  update fraud_alerts set status = 'REVIEW'
  where account_id = p_account_id and status = 'OPEN';
  commit;
end;
/

-- any new txn of 200k+ gets an alert straight away
create or replace trigger trg_big_txn_alert
after insert on transactions
for each row
when (new.amount >= 200000)
begin
  insert into fraud_alerts(txn_id, account_id, risk_score, rules_hit)
  values (:new.txn_id, :new.account_id, 60, 'BIG_TXN_TRIGGER');
end;
/

exec sp_run_fraud_scan;


-- test the trigger and the freeze procedure
insert into transactions(account_id, txn_type, amount, txn_time, city, channel)
values (10, 'TRANSFER', 250000, sysdate, 'Mumbai', 'ONLINE');
commit;

select alert_id, account_id, risk_score, rules_hit from fraud_alerts where rules_hit = 'BIG_TXN_TRIGGER';

exec sp_freeze_account(10);
select account_id, status from accounts where account_id = 10;


-- report views (used by power bi)
create or replace view v_alert_details as
select f.alert_id, f.risk_score, f.rules_hit, f.status,
       t.txn_id, t.txn_type, t.amount, t.txn_time, t.city as txn_city, t.channel,
       a.account_id, c.full_name, c.city as home_city
from fraud_alerts f
join transactions t on t.txn_id = f.txn_id
join accounts a on a.account_id = f.account_id
join customers c on c.customer_id = a.customer_id;

-- top 10 accounts by number of alerts
create or replace view v_high_risk_accounts as
select * from (
  select a.account_id, c.full_name, c.city,
         count(*) as alert_count,
         max(f.risk_score) as max_score,
         round(avg(f.risk_score),1) as avg_score,
         rank() over (order by count(*) desc) as risk_rank
  from fraud_alerts f
  join accounts a on a.account_id = f.account_id
  join customers c on c.customer_id = a.customer_id
  group by a.account_id, c.full_name, c.city
) where risk_rank <= 10;

create or replace view v_alerts_by_rule as
select rules_hit, count(*) as alerts, round(avg(risk_score),1) as avg_score
from fraud_alerts group by rules_hit;

create or replace view v_monthly_fraud as
select trunc(t.txn_time,'MM') as month,
       count(*) as total_txns,
       count(f.alert_id) as flagged_txns,
       round(100 * count(f.alert_id) / count(*), 3) as fraud_pct,
       sum(case when f.alert_id is not null then t.amount end) as amount_at_risk
from transactions t
left join fraud_alerts f on f.txn_id = t.txn_id
group by trunc(t.txn_time,'MM');

create or replace view v_hourly_alerts as
select to_number(to_char(t.txn_time,'HH24')) as hr, count(*) as alerts
from fraud_alerts f join transactions t on t.txn_id = f.txn_id
group by to_number(to_char(t.txn_time,'HH24'));


-- export to csv for power bi
-- save this part as export.sql and run it with @export.sql
-- (typing it at the prompt writes the "SQL>" lines into the csv)
host mkdir C:\blank_project\powerbi

set echo off
set timing off
set pagesize 0
set linesize 1000
set feedback off
set heading off
set trimspool on

spool C:\blank_project\powerbi\monthly_fraud.csv
select 'MONTH,TOTAL_TXNS,FLAGGED_TXNS,FRAUD_PCT,AMOUNT_AT_RISK' from dual;
select to_char(month,'YYYY-MM-DD')||','||total_txns||','||flagged_txns||','||fraud_pct||','||nvl(amount_at_risk,0) from v_monthly_fraud order by month;
spool off

spool C:\blank_project\powerbi\hourly_alerts.csv
select 'HR,ALERTS' from dual;
select hr||','||alerts from v_hourly_alerts order by hr;
spool off

spool C:\blank_project\powerbi\alerts_by_rule.csv
select 'RULES_HIT,ALERTS,AVG_SCORE' from dual;
select rules_hit||','||alerts||','||avg_score from v_alerts_by_rule;
spool off

spool C:\blank_project\powerbi\high_risk_accounts.csv
select 'ACCOUNT_ID,FULL_NAME,CITY,ALERT_COUNT,MAX_SCORE,AVG_SCORE' from dual;
select account_id||','||full_name||','||city||','||alert_count||','||max_score||','||avg_score from v_high_risk_accounts;
spool off

spool C:\blank_project\powerbi\alert_details.csv
select 'ALERT_ID,RISK_SCORE,RULES_HIT,STATUS,TXN_ID,TXN_TYPE,AMOUNT,TXN_TIME,TXN_CITY,CHANNEL,ACCOUNT_ID,FULL_NAME,HOME_CITY' from dual;
select alert_id||','||risk_score||','||rules_hit||','||status||','||txn_id||','||txn_type||','||amount||','||to_char(txn_time,'YYYY-MM-DD HH24:MI:SS')||','||txn_city||','||channel||','||account_id||','||full_name||','||home_city from v_alert_details;
spool off

set heading on
set feedback on
set pagesize 50
