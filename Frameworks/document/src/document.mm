#include "document.h"
#include "OakDocument Private.h"
#include "OakDocumentController.h"
#include "collection.h"
#include <io/io.h>
#include <io/entries.h>
#include <io/resource.h>
#include <regexp/glob.h>
#include <text/ctype.h>
#include <cf/cf.h>
#include <cf/run_loop.h>
#include <ns/ns.h>
#include <oak/debug.h>

OAK_DEBUG_VAR(Document_Scanner);
OAK_DEBUG_VAR(Document_LRU);
OAK_DEBUG_VAR(Document_Tracker);
OAK_DEBUG_VAR(Document);

@interface OakDocumentObserver : NSObject
{
	oak::callbacks_t<document::document_t::callback_t> _callbacks;
	OakDocument* _document;
	document::document_t* _cppDocument;
}
@property (nonatomic, readonly) BOOL hasCallbacks;
@end

namespace document
{
	// ====================
	// = Document Tracker =
	// ====================

	static bool is_inode_valid (ino_t inode, std::string const& path)
	{
		if(inode == 999999999) // Zero-length files on FAT file systems share this magic value
		{
			struct statfs sfsb;
			if(statfs(path.c_str(), &sfsb) == 0)
				return strcasecmp(sfsb.f_fstypename, "msdos") == 0 && strcasecmp(sfsb.f_fstypename, "exfat") == 0;
			perrorf("is_inode_valid: statfs(\"%s\")", path.c_str());
		}
		return true;
	}

	inode_t::inode_t (dev_t device, ino_t inode, std::string const& path) : device(device), inode(inode), valid(true)
	{
		if(!is_inode_valid(inode, path))
		{
			device = 0;
			inode  = 0;
			valid  = false;
		}
	}

	inode_t::inode_t (std::string const& path)
	{
		struct stat buf;
		if(lstat(path.c_str(), &buf) == 0)
		{
			if(is_inode_valid(buf.st_ino, path))
			{
				device = buf.st_dev;
				inode  = buf.st_ino;
				valid  = true;
			}
		}
	}

	bool inode_t::operator< (inode_t const& rhs) const
	{
		return std::make_tuple(valid ? 1 : 0, inode, device) < std::make_tuple(rhs.valid ? 1 : 0, rhs.inode, rhs.device);
	}

	static struct document_tracker_t
	{
		std::vector<document_ptr> all_documents ()
		{
			std::lock_guard<std::mutex> lock(_lock);

			std::vector<document_ptr> res;
			for(auto pair : _documents_by_uuid)
			{
				if(document_ptr doc = pair.second->document.lock())
					res.push_back(doc);
			}
			return res;
		}

		void add (document_ptr doc)
		{
			std::lock_guard<std::mutex> lock(_lock);
			add_no_lock(doc);
		}

		document_ptr create (std::string const& path, inode_t const& inode)
		{
			std::lock_guard<std::mutex> lock(_lock);
			D(DBF_Document_Tracker, bug("%s (%llu, %d)\n", path.c_str(), inode.inode, inode.device););

			auto pathIter = _documents_by_path.find(path);
			if(pathIter != _documents_by_path.end())
			{
				D(DBF_Document_Tracker, bug("re-use document with same path\n"););
				if(document_ptr res = pathIter->second->document.lock())
				{
					if(pathIter->second->inode != inode)
					{
						// TODO If inode has changed, we should check document content against the disk
						D(DBF_Document_Tracker, bug("update inode %llu → %llu\n", pathIter->second->inode.inode, inode.inode););
						remove_no_lock(res->identifier());
						res->_inode = inode;
						add_no_lock(res);
					}
					return res;
				}
				ASSERT(false);
			}

			auto inodeIter = _documents_by_inode.find(inode);
			if(inodeIter != _documents_by_inode.end())
			{
				D(DBF_Document_Tracker, bug("re-use document with different path ‘%s’\n", inodeIter->second->path.c_str()););
				// TODO If the old path no longer exist, we should update document’s path
				if(document_ptr res = inodeIter->second->document.lock())
					return res;
				ASSERT(false);
			}

			D(DBF_Document_Tracker, bug("nothing found, create new document\n"););
			document_ptr res = std::make_shared<document_t>([OakDocument documentWithPath:to_ns(path)]);
			res->_inode = inode;

			add_no_lock(res);
			return res;
		}

		document_ptr find (oak::uuid_t const& uuid)
		{
			std::lock_guard<std::mutex> lock(_lock);
			D(DBF_Document_Tracker, bug("%s\n", to_s(uuid).c_str()););

			auto uuidIter = _documents_by_uuid.find(uuid);
			if(uuidIter != _documents_by_uuid.end())
			{
				D(DBF_Document_Tracker, bug("re-use document with path ‘%s’\n", uuidIter->second->path.c_str()););
				if(document_ptr res = uuidIter->second->document.lock())
					return res;
				ASSERT(false);
			}

			if(OakDocument* document = [OakDocument documentWithIdentifier:[[NSUUID alloc] initWithUUIDBytes:uuid.data]])
			{
				document_ptr res = std::make_shared<document_t>(document);
				res->_inode = inode_t(to_s(document.path));
				add_no_lock(res);
				return res;
			}

			D(DBF_Document_Tracker, bug("nothing found\n"););
			return document_ptr();
		}

		inode_t update_document (oak::uuid_t const& uuid)
		{
			std::lock_guard<std::mutex> lock(_lock);
			D(DBF_Document_Tracker, bug("%s\n", to_s(uuid).c_str()););

			auto it = _documents_by_uuid.find(uuid);
			if(it != _documents_by_uuid.end())
			{
				if(document_ptr doc = it->second->document.lock())
				{
					inode_t newInode(doc->path());
					if(doc->path() != it->second->path || newInode != it->second->inode)
					{
						D(DBF_Document_Tracker, bug("path ‘%s’ → ‘%s’\n", it->second->path.c_str(), doc->path().c_str()););
						D(DBF_Document_Tracker, bug("inode (%llu, %d) → (%llu, %d)\n", it->second->inode.inode, it->second->inode.device, newInode.inode, newInode.device););
						remove_no_lock(uuid);
						doc->_inode = newInode;
						add_no_lock(doc);
					}
					return newInode;
				}
				D(DBF_Document_Tracker, bug("weak reference expired\n"););
				ASSERT(false);
			}
			D(DBF_Document_Tracker, bug("uuid not found\n"););
			ASSERT(it != _documents_by_uuid.end());
			return inode_t();
		}

		void remove (oak::uuid_t const& uuid)
		{
			std::lock_guard<std::mutex> lock(_lock);
			D(DBF_Document_Tracker, bug("%s\n", to_s(uuid).c_str()););

			remove_no_lock(uuid);
		}

	private:
		struct record_t
		{
			oak::uuid_t uuid;
			std::string path;
			inode_t inode;
			document_weak_ptr document;
		};

		typedef std::shared_ptr<record_t> record_ptr;

		std::mutex                        _lock;
		std::map<oak::uuid_t, record_ptr> _documents_by_uuid;
		std::map<std::string, record_ptr> _documents_by_path;
		std::map<inode_t, record_ptr>     _documents_by_inode;

		void add_no_lock (document_ptr doc)
		{
			auto r = std::make_shared<record_t>();
			r->uuid     = doc->identifier();
			r->path     = doc->path();
			r->inode    = doc->_inode;
			r->document = doc;

			ASSERT(_documents_by_uuid.find(r->uuid) == _documents_by_uuid.end());
			_documents_by_uuid.emplace(r->uuid, r);

			if(r->path != NULL_STR)
			{
				ASSERT(_documents_by_path.find(r->path) == _documents_by_path.end());
				_documents_by_path.emplace(r->path, r);
			}

			if(r->inode)
			{
				ASSERT(_documents_by_inode.find(r->inode) == _documents_by_inode.end());
				_documents_by_inode.emplace(r->inode, r);
			}
		}

		void remove_no_lock (oak::uuid_t const& uuid)
		{
			auto it = _documents_by_uuid.find(uuid);
			if(it != _documents_by_uuid.end())
			{
				if(it->second->inode)
					_documents_by_inode.erase(it->second->inode);
				if(it->second->path != NULL_STR)
					_documents_by_path.erase(it->second->path);
				_documents_by_uuid.erase(it);
			}
			ASSERT(it != _documents_by_uuid.end());
		}

	} documents;

	document_ptr create (std::string const& rawPath)                    { std::string const path = path::resolve(rawPath); return path::is_text_clipping(path) ? from_content(path::resource(path, typeUTF8Text, 256)) : documents.create(path, inode_t(path)); }
	document_ptr create (std::string const& path, inode_t const& inode) { return documents.create(path, inode); }
	document_ptr find (oak::uuid_t const& uuid)                         { return documents.find(uuid); }

	document_ptr from_content (std::string const& content, std::string fileType)
	{
		D(DBF_Document, bug("%s\n", fileType.c_str()););

		NSData* data = content != NULL_STR ? [NSData dataWithBytesNoCopy:(void*)content.data() length:content.size() freeWhenDone:NO] : nil;
		document_ptr res = std::make_shared<document_t>([OakDocument documentWithData:data fileType:to_ns(fileType) customName:nil]);
		documents.add(res);
		return res;
	}

} /* document */

// =======================
// = OakDocumentObserver =
// =======================

static std::map<std::string, document::document_t::callback_t::event_t> const ObservedKeys =
{
	{ "path",             document::document_t::callback_t::did_change_path             },
	{ "onDisk",           document::document_t::callback_t::did_change_on_disk_status   },
	{ "fileType",         document::document_t::callback_t::did_change_file_type        },
	{ "open",             document::document_t::callback_t::did_change_open_status      },
	{ "documentEdited",   document::document_t::callback_t::did_change_modified_status  },
	{ "tabSize",          document::document_t::callback_t::did_change_indent_settings, },
	{ "softTabs",         document::document_t::callback_t::did_change_indent_settings, },
};

@implementation OakDocumentObserver
- (id)initWithDocument:(OakDocument*)aDocument cppDocument:(document::document_t*)cppDocument
{
	if((self = [super init]))
	{
		_document    = aDocument;
		_cppDocument = cppDocument;

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(documentContentDidChange:) name:OakDocumentContentDidChangeNotification object:_document];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(documentMarksDidChange:)   name:OakDocumentMarksDidChangeNotification object:_document];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(documentDidSave:)          name:OakDocumentDidSaveNotification object:_document];

		for(auto pair : ObservedKeys)
			[_document addObserver:self forKeyPath:to_ns(pair.first) options:(NSKeyValueObservingOptionNew|NSKeyValueObservingOptionOld) context:nullptr];
	}
	return self;
}

- (void)dealloc
{
	if(auto document = _cppDocument/*.lock()*/)
		_callbacks(&document::document_t::callback_t::document_will_delete, document/*.get()*/);

	for(auto pair : ObservedKeys)
		[_document removeObserver:self forKeyPath:to_ns(pair.first)];

	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)addCallback:(document::document_t::callback_t*)callback
{
	_callbacks.add(callback);
}

- (void)removeCallback:(document::document_t::callback_t*)callback
{
	_callbacks.remove(callback);
}

- (BOOL)hasCallbacks
{
	return _callbacks.begin() != _callbacks.end();
}

- (void)breadcast:(document::document_t::callback_t::event_t)event
{
	if(auto document = _cppDocument/*.lock()*/)
		_callbacks(&document::document_t::callback_t::handle_document_event, document->shared_from_this(), event);
}

- (void)documentContentDidChange:(NSNotification*)aNotification { [self breadcast:document::document_t::callback_t::did_change_content]; }
- (void)documentMarksDidChange:(NSNotification*)aNotification   { [self breadcast:document::document_t::callback_t::did_change_marks]; }

- (void)documentDidSave:(NSNotification*)aNotification
{
	_cppDocument->_inode = document::documents.update_document(_cppDocument->identifier());
	[self breadcast:document::document_t::callback_t::did_save];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)document change:(NSDictionary*)change context:(void*)context
{
	id oldValue = change[NSKeyValueChangeOldKey];
	id newValue = change[NSKeyValueChangeNewKey];
	if(oldValue == newValue || [oldValue isEqual:newValue])
		return;

	auto iter = ObservedKeys.find(to_s(keyPath));
	if(iter != ObservedKeys.end())
		[self breadcast:iter->second];

	if([keyPath isEqualToString:@"path"])
		_cppDocument->_inode = document::documents.update_document(_cppDocument->identifier());
}
@end

namespace document
{
	// =========
	// = Marks =
	// =========

	void remove_marks (std::string const& typeToClear)
	{
		[OakDocument removeAllMarksOfType:to_ns(typeToClear)];
	}

	// ==============
	// = document_t =
	// ==============

	document_t::document_t (OakDocument* document) : _document(document)
	{
	}

	document_t::~document_t ()
	{
		_observer = nil;
		documents.remove(identifier());
	}

	OakDocumentObserver* document_t::observer ()
	{
		if(!_observer)
			_observer = [[OakDocumentObserver alloc] initWithDocument:_document cppDocument:this];
		return _observer;
	}

	oak::uuid_t document_t::identifier () const        { return to_s(_document.identifier.UUIDString); }
	std::string document_t::path () const              { return to_s(_document.path); }
	std::string document_t::virtual_path () const      { return to_s(_document.virtualPath); }
	std::string document_t::custom_name () const       { return to_s(_document.customName); }
	std::string document_t::backup_path () const       { return to_s(_document.backupPath); }
	std::string document_t::display_name () const      { return to_s(_document.displayName); }
	encoding::type document_t::disk_encoding () const  { return encoding::type(to_s(_document.diskNewlines), to_s(_document.diskEncoding)); }
	std::string document_t::file_type () const         { return to_s(_document.fileType); }
	ssize_t document_t::revision () const              { return _document.revision; }
	std::string document_t::content () const           { return to_s(_document.content); }
	bool document_t::is_open () const                  { return _document.isOpen; }
	bool document_t::is_modified () const              { return _document.isDocumentEdited; }
	bool document_t::is_on_disk () const               { return _document.isOnDisk; }
	text::indent_t document_t::indent () const         { return text::indent_t(_document.tabSize, SIZE_T_MAX, _document.softTabs); }
	bool document_t::recent_tracking () const          { return !_document.isRecentTrackingDisabled; }
	std::string document_t::selection () const         { return to_s(_document.selection); }
	std::string document_t::folded () const            { return to_s(_document.folded); }
	ng::index_t document_t::visible_index () const     { return _document.visibleIndex; }

	void document_t::set_path (std::string const& newPath)                   { _document.path = to_ns(newPath); }
	void document_t::set_authorization (osx::authorization_t const& auth)    { _document.authorization = auth; }
	void document_t::set_virtual_path (std::string const& virtualPath)       { _document.virtualPath = to_ns(virtualPath); }
	void document_t::set_custom_name (std::string const& newCustomName)      { _document.customName = to_ns(newCustomName); }
	void document_t::set_file_type (std::string const& newFileType)          { _document.fileType = to_ns(newFileType); }
	void document_t::set_revision (ssize_t rev)                              { _document.revision = rev; }
	void document_t::set_content (std::string const& str)                    { _document.content = to_ns(str); }
	void document_t::set_disk_revision (ssize_t rev)                         { _document.savedRevision = rev; }
	void document_t::set_disk_encoding (encoding::type const& encoding)      { _document.diskNewlines = to_ns(encoding.newlines()); _document.diskEncoding = to_ns(encoding.charset()); }
	void document_t::set_indent (text::indent_t const& indent)               { _document.tabSize = indent.tab_size(); _document.softTabs = indent.soft_tabs(); }
	void document_t::set_recent_tracking (bool flag)                         { _document.recentTrackingDisabled = !flag; }
	void document_t::set_selection (std::string const& sel)                  { _document.selection = to_ns(sel); set_visible_index(ng::index_t()); }
	void document_t::set_folded (std::string const& folded)                  { _document.folded = to_ns(folded); }
	void document_t::set_visible_index (ng::index_t index)                   { _document.visibleIndex = index; }

	ng::buffer_t& document_t::buffer ()                                      { return [_document buffer]; }
	ng::undo_manager_t& document_t::undo_manager ()                          { return [_document undoManager]; }

	void document_t::sync_open (CFStringRef runLoopMode)
	{
		observer(); // Create OakDocumentObserver if it does not already exist

		__block bool didStop = false;

		auto runLoop = std::make_shared<cf::run_loop_t>(runLoopMode);
		[_document loadModalForWindow:nil completionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
			didStop = true;
			runLoop->stop();
		}];

		if(!didStop)
			runLoop->start();
	}

	bool document_t::sync_save (CFStringRef runLoopMode)
	{
		__block bool res = false;
		__block bool didStop = false;

		auto runLoop = std::make_shared<cf::run_loop_t>(runLoopMode);
		[_document saveModalForWindow:nil completionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
			res = result == OakDocumentIOResultSuccess;
			didStop = true;
			runLoop->stop();
		}];

		if(!didStop)
			runLoop->start();

		return res;
	}

	std::map<std::string, std::string> document_t::document_variables () const
	{
		return _document.variables;
	}

	void document_t::show ()              { [OakDocumentController.sharedInstance didTouchDocument:_document]; }
	void document_t::hide ()              { [OakDocumentController.sharedInstance didTouchDocument:_document]; }
	NSInteger document_t::lru () const    { return [OakDocumentController.sharedInstance lruRankForDocument:_document]; }

	bool document_t::backup ()            { return [_document saveBackup:nil]; }
	void document_t::detach_backup ()     { _document.backupPath = nil; }

	void document_t::enumerate_bytes_using_block (void(^block)(char const* bytes, size_t len, bool* stop))
	{
		[_document enumerateByteRangesUsingBlock:^(char const* bytes, NSRange range, BOOL* stop){
			bool shouldStop = false;
			block(bytes, range.length, &shouldStop);
			*stop = shouldStop;
		}];
	}

	void document_t::close ()
	{
		[_document close];
		if(!_document.isOpen && !_observer.hasCallbacks)
			_observer = nil;
	}

	void document_t::add_mark (text::pos_t const& pos, std::string const& mark, std::string const& value)
	{
		[_document setMarkOfType:to_ns(mark) atPosition:pos content:to_ns(value)];
	}

	void document_t::remove_mark (text::pos_t const& pos, std::string const& mark)
	{
		[_document removeMarkOfType:to_ns(mark) atPosition:pos];
	}

	void document_t::remove_all_marks (std::string const& typeToClear)
	{
		[_document removeAllMarksOfType:to_ns(typeToClear)];
	}

	void document_t::add_callback (callback_t* callback)
	{
		[observer() addCallback:callback];
	}

	void document_t::remove_callback (callback_t* callback)
	{
		[_observer removeCallback:callback];
		if(!_document.isOpen && !_observer.hasCallbacks)
			_observer = nil;
	}

	// ===========
	// = Replace =
	// ===========

	bool document_t::replace (std::multimap<std::pair<size_t, size_t>, std::string> const& replacements, uint32_t crc32)
	{
		return [_document performReplacements:replacements checksum:crc32];
	}

} /* document */
