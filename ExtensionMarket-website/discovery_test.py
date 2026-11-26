"""Metadata publication checks: stable revisions, integrity, strict bounds, no source."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from discovery import build_discovery_index, build_registered_discovery_index, write_discovery_index


class DiscoveryPublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.folder=self.root/'Extensions/Example';self.folder.mkdir(parents=True)
        self.manifest={'schemaVersion':2,'runtime':'javascript','identifier':'com.example.tool','displayName':'Example','version':'1.0.0','summary':'A useful example.'}
        (self.folder/'extension.json').write_text(json.dumps(self.manifest))
        (self.folder/'main.js').write_text('TOP SECRET SOURCE SENTINEL')
        self.descriptor={'schemaVersion':1,'description':'Read selected words in context.','capabilities':['Explain words'],'exampleQueries':['What does this word mean?'],'keywords':['dictionary'],'limitations':['Selectable text only'],'platforms':['macOS'],'translations':{'zh-Hans':{'Explain words':'解释单词'}}}
        self.write();self.config={'tools':{}}

    def write(self):
        (self.folder/'discovery.json').write_text(json.dumps(self.descriptor,ensure_ascii=False))

    def test_metadata_only_index_has_content_revision_and_manifest_integrity(self):
        index,manifest=write_discovery_index(self.root,self.root/'published',self.config)
        raw=(self.root/'published/discovery-index.json').read_bytes()
        self.assertEqual(manifest['sha256'],hashlib.sha256(raw).hexdigest());self.assertEqual(manifest['size'],len(raw))
        self.assertEqual(index['extensions'][0]['id'],'com.example.tool')
        self.assertNotIn('TOP SECRET',raw.decode());self.assertNotIn('files',index['extensions'][0]);self.assertNotIn('installSteps',index['extensions'][0])
        reordered=dict(reversed(list(self.descriptor.items())));self.descriptor=reordered;self.write()
        same,_=build_discovery_index(self.root,self.config);self.assertEqual(same['revision'],index['revision'])
        self.descriptor['description']='Changed capabilities.';self.write()
        changed,_=build_discovery_index(self.root,self.config);self.assertNotEqual(changed['revision'],index['revision'])

    def test_missing_descriptor_rejected_and_explicit_legacy_fallback_preserved(self):
        (self.folder/'discovery.json').unlink()
        with self.assertRaisesRegex(ValueError,'requires discovery'):build_discovery_index(self.root,self.config)
        legacy,_=build_discovery_index(self.root,self.config,allow_legacy=True)
        self.assertEqual(legacy['extensions'][0]['description'],self.manifest['summary'])

    def test_registry_seed_reads_only_pinned_metadata_and_preserves_the_marketplace_slug(self):
        requests = []
        metadata = {'extension.json': self.manifest, 'discovery.json': self.descriptor,
                    'marketplace/preview.json': {'slug': 'example-preview'}}

        class Source:
            def read(self, path, maximum, optional=False):
                requests.append(path)
                value = metadata.get(path)
                if optional and value is None:
                    return None
                return json.dumps(metadata[path]).encode()

        index, manifest = build_registered_discovery_index([Source()])
        self.assertEqual(requests, ['extension.json', 'discovery.json', 'marketplace/preview.json'])
        self.assertEqual(index['extensions'][0]['slug'], 'example-preview')
        self.assertEqual(manifest['revision'], index['revision'])
        self.assertNotIn('files', index['extensions'][0])

        del metadata['marketplace/preview.json']
        default_index, _ = build_registered_discovery_index([Source()])
        self.assertEqual(default_index['extensions'][0]['slug'], 'com-example-tool')
        self.descriptor['identifier'] = 'com.example.other'
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            build_registered_discovery_index([Source()])

    def test_bad_schema_limits_types_unknown_fields_and_symlinks_rejected(self):
        cases=[('schemaVersion',True),('exampleQueries',[]),('exampleQueries',['x']*9),('description','x'*4001),('keywords',[3]),('platforms',['x'*129]),('sourceCode','injected'),('translations',{'../bad':{'x':'y'}}),('translations',{'en':{'x':'bad\0text'}})]
        for key,value in cases:
            original=dict(self.descriptor);self.descriptor[key]=value;self.write()
            with self.subTest(key=key),self.assertRaises(ValueError):build_discovery_index(self.root,self.config)
            self.descriptor=original
        self.write();path=self.folder/'discovery.json';path.write_bytes(b' '*(64*1024+1))
        with self.assertRaises(ValueError):build_discovery_index(self.root,self.config)
        path.unlink();path.symlink_to(self.folder/'main.js')
        with self.assertRaises(ValueError):build_discovery_index(self.root,self.config)


    def test_unicode_and_identity_bounds_match_native_catalog_validation(self):
        self.descriptor['description']='😀' * 2000
        self.descriptor['keywords']=[];self.descriptor['limitations']=[];self.write()
        index,_=build_discovery_index(self.root,self.config)
        self.assertEqual(len(index['extensions'][0]['description'].encode('utf-16-le'))//2,4000)
        self.descriptor['description']+='😀';self.write()
        with self.assertRaisesRegex(ValueError,'description'):build_discovery_index(self.root,self.config)
        self.descriptor['description']='Safe';self.descriptor['translations']={'en':{'k'*2001:'value'}};self.write()
        with self.assertRaisesRegex(ValueError,'translation key'):build_discovery_index(self.root,self.config)
        self.descriptor['translations']={};self.write()
        for key,value in [('identifier','Com.example.tool'),('identifier','com.123tool'),('identifier','com.'+'a'*125),('identifier','a.b.c.d.e.f.g.h.i'),('displayName','名'*86),('displayName','Name\ncontrol'),('version','x.y.z'),('version','1.2.3-'+'x'*75)]:
            old=self.manifest[key];self.manifest[key]=value;(self.folder/'extension.json').write_text(json.dumps(self.manifest))
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):build_discovery_index(self.root,self.config)
            self.manifest[key]=old
        (self.folder/'extension.json').write_text(json.dumps(self.manifest))

    def test_browser_stable_identifier_and_config_disagreement(self):
        (self.folder/'extension.json').unlink();(self.folder/'manifest.json').write_text(json.dumps({'name':'Browser','description':'A browser tool.','version':'1.0.0'}))
        self.descriptor['identifier']='com.example.stable-browser';self.write()
        index,_=build_discovery_index(self.root,self.config)
        self.assertEqual(index['extensions'][0]['id'],'com.example.stable-browser');self.assertEqual(index['extensions'][0]['runtime'],'browser')
        with self.assertRaisesRegex(ValueError,'conflicting'):build_discovery_index(self.root,{'tools':{'Example':{'id':'com.example.other'}}})

    def test_retired_tools_are_excluded_from_current_discovery(self):
        (self.folder/'discovery.json').unlink()
        index,_=build_discovery_index(self.root,{'tools':{},'retiredTools':['Example']})
        self.assertEqual(index['extensions'],[])

if __name__=='__main__':unittest.main()
