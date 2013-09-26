#!/usr/bin/env python

import sqlalchemy as sqla
import sqlalchemy.sql as sql
from ConfigParser import SafeConfigParser

import sys

UPDATE_USAGES = False
SEND_MAIL = False


if "--send-mail" in sys.argv:
    SEND_MAIL = True

if "--update-usages" in sys.argv:
    UPDATE_USAGES = True


mail_from = "sysadmin@gc3.lists.uzh.ch"
mail_to = "antonio.s.messina@gmail.com"
mail_subject = "Test OpenStack Usage on cloud1"
mail_text = ""
log = []

nova_cfg_file='/etc/nova/nova.conf'

cfg = SafeConfigParser()
cfg.read(nova_cfg_file)

sql_connection = cfg.get('DEFAULT', 'sql_connection')
db = sqla.create_engine(sql_connection)

metadata = sqla.MetaData(bind=db)
metadata.reflect()

t_vms = metadata.tables['instances']
t_quotas = metadata.tables['quota_usages']

q = sql.select([
    t_vms.c.project_id,
    sqla.func.sum(t_vms.c.vcpus).label('vcpus'),
    sqla.func.sum(t_vms.c.memory_mb).label('ram'),
    sqla.func.count(t_vms.c.id).label('n_instances'),
    sqla.func.sum(t_vms.c.root_gb)]).where(t_vms.c.deleted==0).group_by('project_id')

usages_by_project = db.execute(q)

for project in usages_by_project:
    q = sql.select([t_quotas.c.id,
                    t_quotas.c.in_use,
                    t_quotas.c.resource,
                    t_quotas.c.project_id]).where(
                        sqla.and_(t_quotas.c.deleted==0,
                                  t_quotas.c.project_id==project.project_id))
    for quota in db.execute(q):
        if quota.resource == "instances":
            if project.n_instances != quota.in_use:
                log.append("Instances count mismatch on project %s:"
                           " reported usage: %d, actual usage: %d" % (
                               project.project_id, quota.in_use, project.n_instances))
                if UPDATE_USAGES:
                    log.append(
                        "  updating `%s` table: set `in_use` to %s where id==%s" % (
                            t_quotas.name, project.n_instances, quota.id))
                    db.execute(t_quotas.update().where(t_quotas.c.id==quota.id).values({'in_use':project.n_instances}))

        if quota.resource == "cores":
            if quota.in_use != project.vcpus:
                log.append("CPU count mismatch on project %s: reported usage: %d, actual usage: %d" % (project.project_id, quota.in_use, project.vcpus))
                if UPDATE_USAGES:
                    log.append(
                        "  updating `%s` table: set `in_use` to %s where id==%s" % (
                            t_quotas.name, project.vcpus, quota.id))
                    db.execute(t_quotas.update().where(t_quotas.c.id==quota.id).values({'in_use':project.vcpus}))

        if quota.resource == "ram":
            if quota.in_use != project.ram:
                log.append("RAM count mismatch on project %s: reported usage: %d, actual usage: %d" % (project.project_id, quota.in_use, project.ram))
                if UPDATE_USAGES:
                    log.append(
                        "  updating `%s` table: set `in_use` to %s where id==%s" % (
                            t_quotas.name, project.ram, quota.id))
                    db.execute(t_quotas.update().where(t_quotas.c.id==quota.id).values({'in_use':project.ram}))

if SEND_MAIL:
    import smtplib
    from email.message import Message
    msg = Message()
    msg['Subject'] = mail_subject
    msg['To'] = mail_to
    msg.set_payload(str.join("\n", log))
    s = smtplib.SMTP('localhost')
    s.sendmail(mail_from, [mail_to], msg.as_string())
    s.quit()
else:
    print str.join("\n", log)
