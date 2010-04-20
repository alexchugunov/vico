#import "SFTPConnection.h"
#import "logging.h"

#include <uuid/uuid.h>

#include "log.h"
#include "xmalloc.h"

@implementation SFTPDirectoryEntry
@synthesize filename;
- (SFTPDirectoryEntry *)initWithPointer:(SFTP_DIRENT *)aDirent
{
	self = [super init];
	if (self)
	{
		dirent = aDirent;
		xfree(dirent->longname);
		dirent->longname = NULL;
		filename = [NSString stringWithCString:dirent->filename encoding:NSUTF8StringEncoding]; // XXX: what encoding?
	}
	return self;
}
- (void)finalize
{
	xfree(dirent->filename);
	xfree(dirent);
	[super finalize];
}
- (Attrib *)attributes
{
	return &dirent->a;
}
@end

@implementation SFTPConnection

/* Size of buffer used when copying files */
size_t copy_buffer_len = 32768;

/* Number of concurrent outstanding requests */
size_t num_requests = 64;

@synthesize controlPath;
@synthesize target;

- (SFTPConnection *)initWithTarget:(NSString *)aTarget
{
	self = [super init];
	if (self)
	{
		char *host, *userhost, *cp/*, *file2 = NULL*/;
		char *sftp_server = NULL;

		target = aTarget;
		userhost = strdup([target UTF8String]);

		arglist args;
		bzero(&args, sizeof(args));
		addargs(&args, "%s", SSH_PATH);
		addargs(&args, "-oForwardX11 no");
		addargs(&args, "-oForwardAgent no");
		addargs(&args, "-oPermitLocalCommand no");
		addargs(&args, "-oClearAllForwardings yes");
		addargs(&args, "-v");
		// addargs(&args, "-oControlMaster yes");
		// addargs(&args, "-oControlPath <unique-path>");

		if ((host = strrchr(userhost, '@')) == NULL)
			host = userhost;
		else {
			*host++ = '\0';
			if (!userhost[0]) {
				INFO(@"%s", "Missing username");
				free(userhost);
				return nil;
			}
			addargs(&args, "-l%s", userhost);
		}

		if ((cp = colon(host)) != NULL)
			*cp = '\0';

		host = cleanhostname(host);
		if (!*host) {
			INFO(@"%s", "Missing hostname");
			freeargs(&args);
			return nil;
		}

		// addargs(&args, "-oProtocol %d", sshver);

		/* no subsystem if the server-spec contains a '/' */
		if (sftp_server == NULL || strchr(sftp_server, '/') == NULL)
			addargs(&args, "-s");

		addargs(&args, "%s", host);
		addargs(&args, "%s", (sftp_server != NULL ?
		    sftp_server : "sftp"));
		sshpid = sftp_connect_to_server(SSH_PATH, args.list, &fd_in, &fd_out);
		freeargs(&args);
		if (sshpid == -1)
			return nil;
		conn = do_init(fd_in, fd_out, copy_buffer_len, num_requests);
		free(userhost);
		if (conn == NULL) {
			INFO(@"%s", "Couldn't initialise connection to server");
			return nil;
		}
	}
	return self;
}

- (SFTPConnection *)initWithControlPath:(NSString *)aPath
{
	return nil;
}

// returns static struct
- (Attrib *)stat:(NSString *)path
{
	return do_lstat(conn, [path UTF8String], 0);
}

- (BOOL)isDirectory:(NSString *)path
{
	Attrib *a = [self stat:path];
	if (a == NULL)
		return NO;
	if (!(a->flags & SSH2_FILEXFER_ATTR_PERMISSIONS))
		return NO;
	return (S_ISDIR(a->perm));
}

- (NSArray *)directoryContentsAtPath:(NSString *)path
{
	SFTP_DIRENT **d;
	if (do_readdir(conn, [path UTF8String], &d) != 0)
		return nil;
	
	NSMutableArray *contents = [[NSMutableArray alloc] init];
	int i;
	for (i = 0; d[i]; i++)
		[contents addObject:[[SFTPDirectoryEntry alloc] initWithPointer:d[i]]];

	xfree(d);
	return contents;
}

- (NSString *)currentDirectory
{
	char *pwd = do_realpath(conn, ".");
	if (pwd)
		return [NSString stringWithCString:pwd encoding:NSUTF8StringEncoding]; // XXX: encoding?
	return nil;
		
}

- (NSData *)dataWithContentsOfFile:(NSString *)path
{
	const char *tmpl = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"xi_sftp_download.XXXXXX"] fileSystemRepresentation];
	char *templateFilename = strdup(tmpl);
	int fd = mkstemp(templateFilename);
	if (fd == -1)
	{
		INFO(@"failed to open temporary file: %s", strerror(errno));
		return nil;
	}

	int status = do_download(conn, [path UTF8String], fd, 0);
	unlink(templateFilename);
	if (status == 0)
	{
		NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
		[handle seekToFileOffset:0ULL];
		return [handle readDataToEndOfFile];
	}

	close(fd);
	return nil;
}

- (NSString *)randomFileAtDirectory:(NSString *)aDirectory
{
	char remote_temp_file[37];
	NSString *remote_temp_path = nil;
	do
	{
		uuid_t uuid;
		uuid_generate(uuid);
		uuid_unparse(uuid, remote_temp_file);
		remote_temp_path = [aDirectory stringByAppendingPathComponent:[NSString stringWithUTF8String:remote_temp_file]];
	} while ([self stat:remote_temp_path] != NULL);

	return remote_temp_path;
}

- (BOOL)writeData:(NSData *)data toFile:(NSString *)path error:(NSError **)outError
{
	const char *tmpl = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"xi_sftp_upload.XXXXXX"] fileSystemRepresentation];
	char *templateFilename = strdup(tmpl);
	int fd = mkstemp(templateFilename);
	if (fd == -1) {
		INFO(@"failed to open temporary file: %s", strerror(errno));
		*outError = [NSError errorWithDomain:@"SFTP" code:1 userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithUTF8String:strerror(errno)] forKey:NSLocalizedDescriptionKey]];
		return NO;
	}

	NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
	@try
	{
		[handle writeData:data];
	}
	@catch (NSException *exception)
	{
		INFO(@"FAILED to write to temporary file: %@", exception);
		unlink(templateFilename);
		close(fd);
		*outError = [NSError errorWithDomain:@"SFTP" code:1 userInfo:[NSDictionary dictionaryWithObject:exception forKey:NSLocalizedDescriptionKey]];
		return NO;
	}

	unlink(templateFilename);
	[handle seekToFileOffset:0ULL];

	NSString *remote_temp_path = [self randomFileAtDirectory:[path stringByDeletingLastPathComponent]];

	int status = do_upload(conn, fd, templateFilename, [remote_temp_path UTF8String], [self stat:path], 0);
	close(fd);
	if (status == 0) {
		if (sftp_has_posix_rename(conn)) {
			if (do_rename(conn, [remote_temp_path UTF8String], [path UTF8String]) == 0)
				return YES;
		} else {
			/* Without POSIX rename support, first move away the existing file, rename our temporary file
			 * to correct name, and finally delete the moved away original file.
			 * XXX: doesn't work for new files.
			 */
			NSString *remote_temp_path2 = [self randomFileAtDirectory:[path stringByDeletingLastPathComponent]];
			if (do_rename(conn, [path UTF8String], [remote_temp_path2 UTF8String]) == 0 &&
			    do_rename(conn, [remote_temp_path UTF8String], [path UTF8String]) == 0 &&
			    do_rm(conn, [remote_temp_path2 UTF8String]) == 0)
				return YES;
		}

	}

	*outError = [NSError errorWithDomain:@"SFTP" code:1 userInfo:[NSDictionary dictionaryWithObject:@"Failed to save file." forKey:NSLocalizedDescriptionKey]];

	return NO;
}

@end

