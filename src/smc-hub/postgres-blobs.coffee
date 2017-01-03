###
PostgreSQL -- implementation of queries needed for storage and managing blobs,
including backups, integration with google cloud storage, etc.

**
This code is currently NOT released under any license for use by anybody except SageMath, Inc.

(c) 2016 SageMath, Inc.
**
###

# Bucket used for cheaper longterm storage of blobs (outside of rethinkdb).
# NOTE: We should add this to site configuration, and have it get read once when first
# needed and cached.  Also it would be editable in admin account settings.
BLOB_GCLOUD_BUCKET = 'smc-blobs'

async   = require('async')

misc_node = require('smc-util-node/misc_node')

{defaults} = misc = require('smc-util/misc')
required = defaults.required

{expire_time, one_result, PostgreSQL} = require('./postgres')

class exports.PostgreSQL extends PostgreSQL
    save_blob: (opts) =>
        opts = defaults opts,
            uuid       : undefined # uuid=sha1-based id coming from blob
            blob       : required  # unless check=true, we assume misc_node.uuidsha1(opts.blob) == opts.uuid;
                                   # blob must be a string or Buffer
            ttl        : 0         # object in blobstore will have *at least* this ttl in seconds;
                                   # if there is already something in blobstore with longer ttl, we leave it;
                                   # infinite ttl = 0.
            project_id : required  # the id of the project that is saving the blob
            check      : false     # if true, will give error if misc_node.uuidsha1(opts.blob) != opts.uuid
            cb         : required  # cb(err, ttl actually used in seconds); ttl=0 for infinite ttl
        if not opts.uuid?
            opts.uuid = misc_node.uuidsha1(opts.blob)
        else if opts.check
            uuid = misc_node.uuidsha1(opts.blob)
            if uuid != opts.uuid
                opts.cb("the sha1 uuid (='#{uuid}') of the blob must equal the given uuid (='#{opts.uuid}')")
                return
        rows = ttl = undefined
        async.series([
            (cb) =>
                @_query
                    query : 'SELECT expire FROM blobs'
                    where : "id = $::UUID" : opts.uuid
                    cb    : (err, x) =>
                        rows = x.rows; cb(err)
            (cb) =>
                if rows.length == 0
                    # nothing in DB, so we insert the blob.
                    ttl = opts.ttl
                    @_query
                        query  : "INSERT INTO blobs"
                        values :
                            id         : opts.uuid
                            blob       : opts.blob
                            project_id : opts.project_id
                            count      : 0
                            size       : opts.blob.length
                            created    : new Date()
                            expire     : if ttl then expire_time(ttl)
                        cb     : cb
                else
                    # blob already in the DB, so see if we need to change the expire time
                    @_extend_blob_ttl
                        expire : rows[0].expire
                        ttl    : opts.ttl
                        uuid   : opts.uuid
                        cb     : (err, _ttl) =>
                            ttl = _ttl; cb(err)
        ], (err) => opts.cb(err, ttl))

    # Used internally by save_blob to possibly extend the expire time of a blob.
    _extend_blob_ttl : (opts) =>
        opts = defaults opts,
            expire : undefined    # what expire is currently set to in the database
            ttl    : required     # requested ttl -- extend expire to at least this
            uuid   : required
            cb     : required     # (err, effective ttl (with 0=oo))

        if not opts.expire
            # ttl already infinite -- nothing to do
            opts.cb(undefined, 0)
            return
        new_expire = ttl = undefined
        if opts.ttl
            # saved ttl is finite as is requested one; change in DB if requested is longer
            z = expire_time(opts.ttl)
            if z > opts.expire
                new_expire = z
                ttl = opts.ttl
            else
                ttl = (opts.expire - new Date())/1000.0
        else
            # saved ttl is finite but requested one is infinite
            ttl = new_expire = 0
        if new_expire?
            # change the expire time for the blob already in the DB
            @_query
                query : 'UPDATE blobs'
                where : "id = $::UUID" : opts.uuid
                set   : "expire :: TIMESTAMP " : if new_expire == 0 then undefined else new_expire
                cb    : (err) => opts.cb(err, ttl)
        else
            opts.cb(undefined, ttl)

    get_blob: (opts) =>
        opts = defaults opts,
            uuid       : required
            save_in_db : false  # if true and blob isn't in DB and is only in gcloud, copies to local DB
                                # (for faster access e.g., 20ms versus 5ms -- i.e., not much faster; gcloud is FAST too.)
            touch      : true
            cb         : required   # cb(err) or cb(undefined, blob_value) or cb(undefined, undefined) in case no such blob
        x    = undefined
        blob = undefined
        async.series([
            (cb) =>
                @_query
                    query : "SELECT expire, blob, gcloud FROM blobs"
                    where : "id = $::UUID" : opts.uuid
                    cb    : one_result (err, _x) =>
                        x = _x; cb(err)
            (cb) =>
                if not x?
                    # nothing to do -- blob not in db (probably expired)
                    cb()
                else if x.expire and x.expire <= new Date()
                    # the blob already expired -- background delete it
                    @_query   # delete it (but don't wait for this to finish)
                        query : "DELETE FROM blobs"
                        where : "id = $::UUID" : opts.uuid
                    cb()
                else if x.blob?
                    # blob not expired and is in database
                    blob = x.blob
                    cb()
                else if x.gcloud
                    # blob not available locally, but should be in a Google cloud storage bucket -- try to get it
                    @gcloud().bucket(name: x.gcloud).read
                        name : opts.uuid
                        cb   : (err, _blob) =>
                            if err
                                cb(err)
                            else
                                blob = _blob
                                cb()
                                if opts.save_in_db
                                    # also save in database so will be faster next time (again, don't wait on this)
                                    @_query   # delete it (but don't wait for this to finish)
                                        query : "UPDATE blobs"
                                        set   : {blob : blob}
                                        where : "id = $::UUID" : opts.uuid
                else
                    # blob not local and not in gcloud -- this shouldn't happen (just view this as "expired" by not setting blob)
                    cb()
        ], (err) =>
            opts.cb(err, blob)
            if blob? and opts.touch
                # blob was pulled from db or gcloud, so note that it was accessed (updates a counter)
                @touch_blob(uuid : opts.uuid)
        )

    touch_blob: (opts) =>
        opts = defaults opts,
            uuid : required
            cb   : undefined
        @_query
            query : "UPDATE blobs SET count = count + 1, last_active = NOW()"
            where : "id = $::UUID" : opts.uuid
            cb    : opts.cb

    # Return gcloud API interface
    gcloud: () =>
        return @_gcloud ?= require('./smc_gcloud').gcloud()

    # Uploads the blob with given sha1 uuid to gcloud storage, if it hasn't already
    # been uploaded there.
    copy_blob_to_gcloud: (opts) =>
        opts = defaults opts,
            uuid   : required  # uuid=sha1-based uuid coming from blob
            bucket : BLOB_GCLOUD_BUCKET # name of bucket
            force  : false      # if true, upload even if already uploaded
            remove : false      # if true, deletes blob from database after successful upload to gcloud (to free space)
            cb     : undefined  # cb(err)
        x = undefined
        async.series([
            (cb) =>
                @_query
                    query : "SELECT blob, gcloud FROM blobs"
                    where : "id = $::UUID" : opts.uuid
                    cb    : one_result (err, _x) =>
                        x = _x
                        if err
                            cb(err)
                        else if not x?
                            cb('no such blob')
                        else if not x.blob and not x.gcloud
                            cb('blob not available -- this should not be possible')
                        else if not x.blob and opts.force
                            cb("blob can't be re-uploaded since it was already deleted")
                        else
                            cb()
            (cb) =>
                if x.gcloud? and not opts.force
                    # already uploaded -- don't need to do anything
                    cb(); return
                if not x.blob?
                    # blob already deleted locally
                    cb(); return
                # upload to Google cloud storage
                @gcloud().bucket(name:opts.bucket).write
                    name    : opts.uuid
                    content : x.blob
                    cb      : cb
            (cb) =>
                if not x.blob?
                    # no blob in db; nothing further to do.
                    cb()
                else
                    # We successful upload to gcloud -- set x.gcloud
                    set = {gcloud: opts.bucket}
                    if opts.remove
                        set.blob = null   # remove blob content from database to save space
                    @_query
                        query : "UPDATE blobs"
                        where : "id = $::UUID" : opts.uuid
                        set   : set
                        cb    : cb
        ], (err) => opts.cb?(err))

    ###
    Backup limit blobs that previously haven't been dumped to blobs, and put them in
    a tarball in the given path.  The tarball's name is the time when the backup starts.
    The tarball is compressed using gzip compression.

       db._error_thresh=1e6; db.backup_blobs_to_tarball(limit:10000,path:'/backup/tmp-blobs',repeat_until_done:60, cb:done())

    I have not written code to restore from these tarballs.  Assuming the database has been restored,
    so there is an entry in the blobs table for each blob, it would suffice to upload the tarballs,
    then copy their contents straight into the BLOB_GCLOUD_BUCKET gcloud bucket, and that’s it.
    If we don't have the blobs table in the DB, make dummy entries from the blob names in the tarballs.

    TODO : there's a whole bunch of throttling code that was critical with RethinkDB below;
           however, maybe this isn't needed with Postgres!
    ###
    backup_blobs_to_tarball: (opts) =>
        opts = defaults opts,
            limit             : 10000    # number of blobs to backup
            path              : required # path where [timestamp].tar file is placed
            throttle          : 0        # wait this many seconds between pulling blobs from database
            repeat_until_done : 0        # if positive, keeps re-call'ing this function until no more
                                         # results to backup (pauses this many seconds between)
            map_limit         : 5
            cb                : undefined# cb(err, '[timestamp].tar')
        dbg     = @_dbg("backup_blobs_to_tarball(limit=#{opts.limit},path='#{opts.path}')")
        join    = require('path').join
        dir     = misc.date_to_snapshot_format(new Date())
        target  = join(opts.path, dir)
        tarball = target + '.tar.gz'
        v       = undefined
        to_remove = []
        async.series([
            (cb) =>
                dbg("make target='#{target}'")
                fs.mkdir(target, cb)
            (cb) =>
                dbg("get blobs that we need to back up")
                @_query
                    query : "SELECT id FROM blobs"
                    where : "expire IS NULL and backup IS NOT true"
                    limit : opts.limit
                    cb    : all_results 'id', (err, x) =>
                        v = x; cb(err)
            (cb) =>
                dbg("backing up #{v.length} blobs")
                f = (id, cb) =>
                    @get_blob
                        uuid  : id
                        touch : false
                        cb    : (err, blob) =>
                            if err
                                dbg("ERROR! blob #{id} -- #{err}")
                                cb(err)
                            else if blob?
                                dbg("got blob #{id} from db -- now write to disk")
                                to_remove.push(id)
                                fs.writeFile join(target, id), blob, (err) =>
                                    if opts.throttle
                                        setTimeout(cb, opts.throttle*1000)
                                    else
                                        cb()
                            else
                                dbg("blob #{id} is expired, so nothing to be done, ever.")
                                cb()
                async.mapLimit(v, opts.map_limit, f, cb)
            (cb) =>
                dbg("successfully wrote all blobs to files; now make tarball")
                misc_node.execute_code
                    command : 'tar'
                    args    : ['zcvf', tarball, dir]
                    path    : opts.path
                    timeout : 3600
                    cb      : cb
            (cb) =>
                dbg("remove temporary blobs")
                f = (x, cb) =>
                    fs.unlink(join(target, x), cb)
                async.mapLimit(to_remove, 10, f, cb)
            (cb) =>
                dbg("remove temporary directory")
                fs.rmdir(target, cb)
            (cb) =>
                dbg("backup succeeded completely -- mark all blobs as backed up")
                @_query
                    query : "UPDATE blobs"
                    set   : {backup: true}
                    where : "id = ANY($)" : v
                    cb    : cb
        ], (err) =>
            if err
                dbg("ERROR: #{err}")
                opts.cb?(err)
            else
                dbg("done")
                if opts.repeat_until_done and to_remove.length == opts.limit
                    f = () =>
                        @backup_blobs_to_tarball(opts)
                    setTimeout(f, opts.repeat_until_done*1000)
                else
                    opts.cb?(undefined, tarball)
        )

    ###
    Copied all blobs that will never expire to a google cloud storage bucket.

        errors={}; db.copy_all_blobs_to_gcloud(limit:500, cb:done(), remove:true, repeat_until_done_s:10, errors:errors)
    ###
    copy_all_blobs_to_gcloud: (opts) =>
        opts = defaults opts,
            bucket    : BLOB_GCLOUD_BUCKET # name of bucket
            limit     : 1000               # copy this many in each batch
            map_limit : 1                  # copy this many at once.
            throttle  : 0                  # wait this many seconds between uploads
            repeat_until_done_s : 0        # if nonzero, waits this many seconds, then recalls this function until nothing gets uploaded.
            errors    : {}                 # used to accumulate errors
            remove    : false
            cb        : required
        dbg = @_dbg("copy_all_blobs_to_gcloud")
        dbg()
        # This query selects the blobs that will never expire, but have not yet
        # been copied to Google cloud storage.
        dbg("getting blob id's...")
        @_query
            query : 'SELECT id, size FROM blos'
            where : "expire IS NULL AND gcloud IS NULL"
            limit : opts.limit
            cb    : all_results (err, v) =>
                if err
                    dbg("fail: #{err}")
                    opts.cb(err)
                else
                    n = v.length; m = 0
                    dbg("got #{n} blob id's")
                    f = (x, cb) =>
                        m += 1
                        k = m; start = new Date()
                        dbg("**** #{k}/#{n}: uploading #{x.id} of size #{x.size/1000}KB")
                        @copy_blob_to_gcloud
                            uuid   : x.id
                            bucket : opts.bucket
                            remove : opts.remove
                            cb     : (err) =>
                                dbg("**** #{k}/#{n}: finished -- #{err}; size #{x.size/1000}KB; time=#{new Date() - start}ms")
                                if err
                                    opts.errors[x.id] = err
                                if opts.throttle
                                    setTimeout(cb, 1000*opts.throttle)
                                else
                                    cb()
                    async.mapLimit v, opts.map_limit, f, (err) =>
                        dbg("finished this round -- #{err}")
                        if opts.repeat_until_done_s and v.length > 0
                            dbg("repeat_until_done triggering another round")
                            setTimeout((=> @copy_all_blobs_to_gcloud(opts)), opts.repeat_until_done_s*1000)
                        else
                            dbg("done : #{misc.to_json(opts.errors)}")
                            opts.cb(if misc.len(opts.errors) > 0 then opts.errors)

    blob_maintenance: (opts) =>
        opts = defaults opts,
            path              : '/backup/blobs'
            map_limit         : 2
            blobs_per_tarball : 10000
            throttle          : 0
            cb                : undefined
        dbg = @dbg("blob_maintenance()")
        dbg()
        async.series([
            (cb) =>
                dbg("backup_blobs_to_tarball")
                @backup_blobs_to_tarball
                    throttle          : opts.throttle
                    limit             : opts.blobs_per_tarball
                    path              : opts.path
                    map_limit         : opts.map_limit
                    repeat_until_done : 5
                    cb                : cb
            (cb) =>
                dbg("copy_all_blobs_to_gcloud")
                errors = {}
                @copy_all_blobs_to_gcloud
                    limit               : 1000
                    repeat_until_done_s : 5
                    errors              : errors
                    remove              : true
                    map_limit           : opts.map_limit
                    throttle            : opts.throttle
                    cb                  : (err) =>
                        if misc.len(errors) > 0
                            dbg("errors! #{misc.to_json(errors)}")
                        cb(err)
        ], (err) =>
            opts.cb?(err)
        )

    remove_blob_ttls: (opts) =>
        opts = defaults opts,
            uuids : required   # uuid=sha1-based from blob
            cb    : required   # cb(err)
        @_query
            query : "UPDATE blobs"
            set   : {expire: null}
            where : "id::UUID = ANY($)" : opts.uuids
            cb    : opts.cb

    # If blob has been copied to gcloud, remove the BLOB part of the data
    # from the database (to save space).  If not copied, copy it to gcloud,
    # then remove from database.
    close_blob: (opts) =>
        opts = defaults opts,
            uuid   : required   # uuid=sha1-based from blob
            bucket : BLOB_GCLOUD_BUCKET # name of bucket
            cb     : undefined   # cb(err)
        async.series([
            (cb) =>
                # ensure blob is in gcloud
                @_query
                    query : 'SELECT gcloud FROM blobs'
                    where : 'id = $::UUID' : opts.uuid
                    cb    : one_result 'gcloud', (err, gcloud) =>
                        if err
                            cb(err)
                        else if not gcloud
                            # not yet copied to gcloud storage
                            @copy_blob_to_gcloud
                                uuid   : opts.uuid
                                bucket : opts.bucket
                                cb     : cb
                        else
                            # copied already
                            cb()
            (cb) =>
                # now blob is in gcloud -- delete blob data in database
                @_query
                    query : 'SELECT gcloud FROM blobs'
                    where : 'id = $::UUID' : opts.uuid
                    set   : {blob: null}
                    cb    : cb
        ], (err) => opts.cb?(err))



