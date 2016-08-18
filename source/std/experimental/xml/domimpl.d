/*
*             Copyright Lodovico Giaretta 2016 - .
*  Distributed under the Boost Software License, Version 1.0.
*      (See accompanying file LICENSE_1_0.txt or copy at
*            http://www.boost.org/LICENSE_1_0.txt)
*/

/++
+   Provides an implementation of the DOM Level 3 specification.
+
+   Authors:
+   Lodovico Giaretta
+
+   License:
+   <a href="http://www.boost.org/LICENSE_1_0.txt">Boost License 1.0</a>.
+
+   Copyright:
+   Copyright Lodovico Giaretta 2016 --
+/

module std.experimental.xml.domimpl;

import std.experimental.xml.interfaces;
import dom = std.experimental.xml.dom;
import std.typecons: rebindable, Flag;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator;

/++
+   An implementation of $(LINK2 ../dom/DOMImplementation, `std.experimental.xml.dom.DOMImplementation`).
+   
+   It allows to specify a custom allocator to be used when creating instances of the DOM classes.
+   As keeping track of the lifetime of every node would be very complex, this implementation
+   does not try to do so. Instead, no object is ever deallocated; it is the users responsibility
+   to directly free the allocator memory when all objects are no longer reachable.
+/
class DOMImplementation(DOMString, Alloc = shared(GCAllocator), ErrorHandler = bool delegate(dom.DOMError!DOMString))
                        : dom.DOMImplementation!DOMString
{
    mixin UsesAllocator!(Alloc, true);
    
    override
    {
        DocumentType createDocumentType(DOMString qualifiedName, DOMString publicId, DOMString systemId)
        {
            auto res = allocator.make!DocumentType();
            res.outer = this;
            res._name = qualifiedName;
            res._publicId = publicId;
            res._systemId = systemId;
            return res;
        }
        Document createDocument(DOMString namespaceURI, DOMString qualifiedName, dom.DocumentType!DOMString _doctype)
        {
            auto doctype = cast(DocumentType)_doctype;
            if (_doctype && !doctype)
                throw allocator.make!DOMException(dom.ExceptionCode.WRONG_DOCUMENT);
                
            auto doc = allocator.make!Document;
            doc.outer = this;
            doc._ownerDocument = doc;
            doc._doctype = doctype;
            doc._config = allocator.make!DOMConfiguration();
            
            if (namespaceURI)
            {
                if (!qualifiedName)
                    throw allocator.make!DOMException(dom.ExceptionCode.NAMESPACE);
                doc.appendChild(doc.createElementNS(namespaceURI, qualifiedName));
            }
            else if (qualifiedName)
                doc.appendChild(doc.createElement(qualifiedName));
            
            return doc;
        }
        bool hasFeature(string feature, string version_)
        {
            return (feature == "Core" || feature == "XML")
                && (version_ == "1.0" || version_ == "2.0" || version_ == "3.0");
        }
        DOMImplementation getFeature(string feature, string version_)
        {
            if (hasFeature(feature, version_))
                return this;
            else
                return null;
        }
    }
    
    class DOMException: dom.DOMException
    {
        pure nothrow @nogc @safe this(dom.ExceptionCode code, string file = __FILE__, size_t line = __LINE__)
        {
            _code = code;
            super("", file, line);
        }
        override @property dom.ExceptionCode code()
        {
            return _code;
        }
        private dom.ExceptionCode _code;
    }
    abstract class Node: dom.Node!DOMString
    {
        override
        {
            @property Node parentNode() { return _parentNode; }
            @property Node previousSibling() { return _previousSibling; }
            @property Node nextSibling() { return _nextSibling; }
            @property Document ownerDocument() { return _ownerDocument; }
    
            bool isSameNode(dom.Node!DOMString other)
            {
                return this is other;
            }
            bool isEqualNode(dom.Node!DOMString other)
            {
                import std.traits: AliasSeq;
            
                if (!other || nodeType != other.nodeType)
                    return false;
                    
                foreach (field; AliasSeq!("nodeName", "localName", "namespaceURI", "prefix", "nodeValue"))
                {
                    mixin("auto a = " ~ field ~ ";\n");
                    mixin("auto b = other." ~ field ~ ";\n");
                    if ((a is null && b !is null) || (b is null && a !is null) || (a !is null && b !is null && a != b))
                        return false;
                }
                
                auto thisWithChildren = cast(NodeWithChildren)this;
                if (thisWithChildren)
                {
                    auto otherChild = other.firstChild;
                    foreach (child; thisWithChildren.childNodes)
                    {
                        if (!child.isEqualNode(otherChild))
                            return false;
                        otherChild = otherChild.nextSibling;
                    }
                    if (otherChild !is null)
                        return false;
                }
                    
                return true;
            }
    
            dom.UserData setUserData(string key, dom.UserData data, dom.UserDataHandler!DOMString handler)
            {
                userData[key] = data;
                if (handler)
                    userDataHandlers[key] = handler;
                return data;
            }
            dom.UserData getUserData(string key) const
            {
                if (key in userData)
                    return userData[key];
                return dom.UserData(null);
            }
            
            bool isSupported(string feature, string version_)
            {
                return (feature == "Core" || feature == "XML")
                    && (version_ == "1.0" || version_ == "2.0" || version_ == "3.0");
            }
            Node getFeature(string feature, string version_)
            {
                if (isSupported(feature, version_))
                    return this;
                else
                    return null;
            }
        }
        private
        {
            dom.UserData[string] userData;
            dom.UserDataHandler!DOMString[string] userDataHandlers;
            Node _previousSibling, _nextSibling, _parentNode;
            Document _ownerDocument;
            
            // internal methods
            Element parentElement()
            {
                auto parent = parentNode;
                while (parent && parent.nodeType != dom.NodeType.ELEMENT)
                    parent = parent.parentNode;
                return cast(Element)parent;
            }
            void performClone(Node dest, bool deep)
            {
                foreach (data; userDataHandlers.byKeyValue)
                {
                    auto value = data.value;
                    // putting data.value directly in the following line causes an error; should investigate further
                    value(dom.UserDataOperation.NODE_CLONED, data.key, userData[data.key], this, dest);
                }
            }
        }
        // method that must be overridden
        // just because otherwise it doesn't work [bugzilla 16318]
        abstract override DOMString nodeName();
        // methods specialized in NodeWithChildren
        override
        {
            @property dom.NodeList!DOMString childNodes()
            {
                class EmptyList: dom.NodeList!DOMString
                {
                    @property size_t length() { return 0; }
                    Node item(size_t i) { return null; }
                }
                static EmptyList emptyList;
                if (!emptyList)
                    emptyList = allocator.make!EmptyList;
                return emptyList;
            }
            @property Node firstChild() { return null; }
            @property Node lastChild() { return null; }
            
            Node insertBefore(dom.Node!DOMString _newChild, dom.Node!DOMString _refChild)
            {
                throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
            }
            Node replaceChild(dom.Node!DOMString newChild, dom.Node!DOMString oldChild)
            {
                throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
            }
            Node removeChild(dom.Node!DOMString oldChild)
            {
                throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
            }
            Node appendChild(dom.Node!DOMString newChild)
            {
                throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
            }
            bool hasChildNodes() const { return false; }
        }
        // methods specialized in Element
        override
        {
            @property dom.NamedNodeMap!DOMString attributes() { return null; }
            bool hasAttributes() { return false; }
        }
        // methods specialized in various subclasses
        override
        {
            @property DOMString nodeValue() { return null; }
            @property void nodeValue(DOMString) {}
            @property DOMString textContent() { return null; }
            @property void textContent(DOMString) {}
            @property DOMString baseURI()
            {
                if (parentNode)
                    return parentNode.baseURI;
                return null;
            }
            
            Node cloneNode(bool deep) { return null; }
        }
        // methods specialized in Element and Attribute
        override
        {
            @property DOMString localName() { return null; }
            @property DOMString prefix() { return null; }
            @property void prefix(DOMString) { }
            @property DOMString namespaceURI() { return null; }
        }
        // methods specialized in Document, Element and Attribute
        override
        {
            DOMString lookupPrefix(DOMString namespaceURI)
            {
                if (!namespaceURI)
                    return null;
                    
                switch (nodeType) with (dom.NodeType)
                {
                    case ENTITY:
                    case NOTATION:
                    case DOCUMENT_FRAGMENT:
                    case DOCUMENT_TYPE:
                        return null;
                    case ATTRIBUTE:
                        Attr attr = cast(Attr)this;
                        if (attr.ownerElement)
                            return attr.ownerElement.lookupNamespacePrefix(namespaceURI, attr.ownerElement);
                        return null;
                    default:
                        auto parentElement = parentElement();
                        if (parentElement)
                            return parentElement.lookupNamespacePrefix(namespaceURI, parentElement);
                        return null;
                }
            }
            DOMString lookupNamespaceURI(DOMString prefix)
            {
                switch (nodeType) with (dom.NodeType)
                {
                    case ENTITY:
                    case NOTATION:
                    case DOCUMENT_TYPE:
                    case DOCUMENT_FRAGMENT:
                        return null;
                    case ATTRIBUTE:
                        auto attr = cast(Attr)this;
                        if (attr.ownerElement)
                            return attr.ownerElement.lookupNamespaceURI(prefix);
                        return null;
                    default:
                        auto parentElement = parentElement();
                        if (parentElement)
                            return parentElement.lookupNamespaceURI(prefix);
                            
                        return null;
                }
            }
            bool isDefaultNamespace(DOMString namespaceURI)
            {
                switch (nodeType) with (dom.NodeType)
                {
                    case ENTITY:
                    case NOTATION:
                    case DOCUMENT_TYPE:
                    case DOCUMENT_FRAGMENT:
                        return false;
                    case ATTRIBUTE:
                        auto attr = cast(Attr)this;
                        if (attr.ownerElement)
                            return attr.ownerElement.isDefaultNamespace(namespaceURI);
                        return false;
                    default:
                        auto parentElement = parentElement();
                        if (parentElement)
                            return parentElement.isDefaultNamespace(namespaceURI);
                        return false;
                }
            }
        }
        // TODO methods
        override
        {
            void normalize() {}
            dom.DocumentPosition compareDocumentPosition(dom.Node!DOMString other) { return dom.DocumentPosition.IMPLEMENTATION_SPECIFIC; }
        }
        // method not required by the spec, specialized in NodeWithChildren
        bool isAncestor(Node other) { return false; }
    }
    private abstract class NodeWithChildren: Node
    {
        override
        {
            @property ChildList childNodes()
            {
                auto res = allocator.make!ChildList();
                res.outer = this;
                res.currentChild = firstChild;
                return res;
            }
            @property Node firstChild()
            {
                return _firstChild;
            }
            @property Node lastChild()
            {
                return _lastChild;
            }
            
            Node insertBefore(dom.Node!DOMString _newChild, dom.Node!DOMString _refChild)
            {
                if (!_refChild)
                    return appendChild(_newChild);
                    
                auto newChild = cast(Node)_newChild;
                auto refChild = cast(Node)_refChild;
                if (!newChild || !refChild || newChild.ownerDocument !is ownerDocument)
                    throw allocator.make!DOMException(dom.ExceptionCode.WRONG_DOCUMENT);
                if (this is newChild || newChild.isAncestor(this) || newChild is refChild)
                    throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                if (refChild.parentNode !is this)
                    throw allocator.make!DOMException(dom.ExceptionCode.NOT_FOUND);
                    
                if (newChild.nodeType == dom.NodeType.DOCUMENT_FRAGMENT)
                {
                    for (auto child = rebindable(newChild); child !is null; child = child.nextSibling)
                        insertBefore(child, refChild);
                    return newChild;
                }
                    
                if (newChild.parentNode)
                    newChild.parentNode.removeChild(newChild);
                newChild._parentNode = this;
                if (refChild.previousSibling)
                {
                    refChild.previousSibling._nextSibling = newChild;
                    newChild._previousSibling = refChild.previousSibling;
                }
                refChild._previousSibling = newChild;
                newChild._nextSibling = refChild;
                if (firstChild is refChild)
                    _firstChild = newChild;
                return newChild;
            }
            Node replaceChild(dom.Node!DOMString newChild, dom.Node!DOMString oldChild)
            {
                insertBefore(newChild, oldChild);
                return removeChild(oldChild);
            }
            Node removeChild(dom.Node!DOMString _oldChild)
            {
                auto oldChild = cast(Node)_oldChild;
                if (!oldChild || oldChild.parentNode !is this)
                    throw allocator.make!DOMException(dom.ExceptionCode.NOT_FOUND);

                if (oldChild is firstChild)
                    _firstChild = oldChild.nextSibling;
                else
                    oldChild.previousSibling._nextSibling = oldChild.nextSibling;

                if (oldChild is lastChild)
                    _lastChild = oldChild.previousSibling;
                else
                    oldChild.nextSibling._previousSibling = oldChild.previousSibling;

                oldChild._parentNode = null;
                oldChild._previousSibling = null;
                oldChild._nextSibling = null;
                return oldChild;
            }
            Node appendChild(dom.Node!DOMString _newChild)
            {
                auto newChild = cast(Node)_newChild;
                if (!newChild || newChild.ownerDocument !is ownerDocument)
                    throw allocator.make!DOMException(dom.ExceptionCode.WRONG_DOCUMENT);
                if (this is newChild || newChild.isAncestor(this))
                    throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                if (newChild.parentNode !is null)
                    newChild.parentNode.removeChild(newChild);
                    
                if (newChild.nodeType == dom.NodeType.DOCUMENT_FRAGMENT)
                {
                    for (auto node = rebindable(newChild.firstChild); node !is null; node = node.nextSibling)
                        appendChild(node);
                    return newChild;
                }
                    
                newChild._parentNode = this;
                if (lastChild)
                {
                    newChild._previousSibling = lastChild;
                    lastChild._nextSibling = newChild;
                }
                else
                    _firstChild = newChild;
                _lastChild = newChild;
                return newChild;
            }
            bool hasChildNodes() const
            {
                return _firstChild !is null;
            }
            bool isAncestor(Node other)
            {
                for (auto child = rebindable(firstChild); child !is null; child = child.nextSibling)
                {
                    if (child is other)
                        return true;
                    if (child.isAncestor(other))
                        return true;
                }
                return false;
            }
            
            @property DOMString textContent()
            {
                DOMString result;
                for (auto child = rebindable(firstChild); child !is null; child = child.nextSibling)
                {
                    if (child.nodeType != dom.NodeType.COMMENT &&
                        child.nodeType != dom.NodeType.PROCESSING_INSTRUCTION)
                    {
                        result ~= child.textContent;
                    }
                }
                return result;
            }
            @property void textContent(DOMString newVal)
            {
                while (firstChild)
                    removeChild(firstChild);
                    
                _firstChild = _lastChild = ownerDocument.createTextNode(newVal);
            }
        }
        private
        {
            Node _firstChild, _lastChild;
            
            void performClone(NodeWithChildren dest, bool deep)
            {
                super.performClone(dest, deep);
                if (deep)
                    foreach (child; childNodes)
                    {
                        auto childClone = child.cloneNode(true);
                        dest.appendChild(childClone);
                    }
            }
        }
        class ChildList: dom.NodeList!DOMString
        {
            private Node currentChild;
            // methods specific to NodeList
            override
            {
                Node item(size_t index)
                {
                    auto result = rebindable(this.outer.firstChild);
                    for (size_t i = 0; i < index && result !is null; i++)
                    {
                        result = result.nextSibling;
                    }
                    return result;
                }
                @property size_t length()
                {
                    auto child = rebindable(this.outer.firstChild);
                    size_t result = 0;
                    while (child)
                    {
                        result++;
                        child = child.nextSibling;
                    }
                    return result;
                }
            }
            // range interface
            auto front() { return currentChild; }
            void popFront() { currentChild = currentChild.nextSibling; }
            bool empty() { return currentChild is null; }
        }
    }
    class DocumentFragment: NodeWithChildren, dom.DocumentFragment!DOMString
    {
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.DOCUMENT_FRAGMENT; }
            @property DOMString nodeName() { return "#document-fragment"; }
        }
    }
    class Document: NodeWithChildren, dom.Document!DOMString
    {
        // specific to Document
        override
        {
            @property DocumentType doctype() { return _doctype; }
            @property DOMImplementation implementation() { return this.outer; }
            @property Element documentElement() { return _root; }
            
            Element createElement(DOMString tagName)
            {
                auto res = allocator.make!Element();
                res.outer = this.outer;
                res._name = tagName;
                res._ownerDocument = this;
                res._attrs = allocator.make!(Element.Map)();
                res._attrs.outer = res;
                return res;
            }
            Element createElementNS(DOMString namespaceURI, DOMString qualifiedName)
            {
                auto res = allocator.make!Element();
                res.outer = this.outer;
                res.setQualifiedName(qualifiedName);
                res._namespaceURI = namespaceURI;
                res._ownerDocument = this;
                res._attrs = allocator.make!(Element.Map)();
                res._attrs.outer = res;
                return res;
            }
            DocumentFragment createDocumentFragment()
            {
                auto res = allocator.make!DocumentFragment();
                res.outer = this.outer;
                res._ownerDocument = this;
                return res;
            }
            Text createTextNode(DOMString data)
            {
                auto res = allocator.make!Text();
                res.outer = this.outer;
                res._data = data;
                res._ownerDocument = this;
                return res;
            }
            Comment createComment(DOMString data)
            {
                auto res = allocator.make!Comment();
                res.outer = this.outer;
                res._data = data;
                res._ownerDocument = this;
                return res;
            }
            CDATASection createCDATASection(DOMString data)
            {
                auto res = allocator.make!CDATASection();
                res.outer = this.outer;
                res._data = data;
                res._ownerDocument = this;
                return res;
            }
            ProcessingInstruction createProcessingInstruction(DOMString target, DOMString data)
            {
                auto res = allocator.make!ProcessingInstruction();
                res.outer = this.outer;
                res._target = target;
                res._data = data;
                res._ownerDocument = this;
                return res;
            } 
            Attr createAttribute(DOMString name)
            {
                auto res = allocator.make!Attr();
                res.outer = this.outer;
                res._name = name;
                res._ownerDocument = this;
                return res;
            }
            Attr createAttributeNS(DOMString namespaceURI, DOMString qualifiedName)
            {
                auto res = allocator.make!Attr();
                res.outer = this.outer;
                res.setQualifiedName(qualifiedName);
                res._namespaceURI = namespaceURI;
                res._ownerDocument = this;
                return res;
            } 
            EntityReference createEntityReference(DOMString name) { return null; }
            
            dom.NodeList!DOMString getElementsByTagName(DOMString tagname)
            {
                class ElementList: dom.NodeList!DOMString
                {
                    private Document document;
                    private DOMString tagname;
                    
                    private Element findNext(Node node)
                    {
                        auto childList = node.childNodes;
                        auto len = childList.length;
                        foreach (i; 0..len)
                        {
                            auto item = childList.item(i);
                            if (item.nodeType == dom.NodeType.ELEMENT && item.nodeName == tagname)
                                return cast(Element)item;
                                
                            auto res = findNext(cast(Node)item);
                            if (res !is null)
                                return res;
                        }
                        return null;
                    }
                    
                    // methods specific to NodeList
                    override
                    {
                        @property size_t length()
                        {
                            size_t res = 0;
                            auto node = findNext(document);
                            while (node !is null)
                            {
                                res++;
                                node = findNext(node);
                            }
                            return res;
                        }
                        Element item(size_t i)
                        {
                            auto res = findNext(document);
                            while (res && i > 0)
                            {
                                res = findNext(res);
                                i--;
                            }
                            return res;
                        }
                    }
                }
                auto res = allocator.make!ElementList;
                res.document = this;
                res.tagname = tagname;
                return res;
            }
            dom.NodeList!DOMString getElementsByTagNameNS(DOMString namespaceURI, DOMString localName)
            {
                class ElementList: dom.NodeList!DOMString
                {
                    private Document document;
                    private DOMString namespaceURI, localName;
                    
                    private Element findNext(Node node)
                    {
                        auto childList = node.childNodes;
                        auto len = childList.length;
                        foreach (i; 0..len)
                        {
                            auto item = childList.item(i);
                            if (item.nodeType == dom.NodeType.ELEMENT)
                            {
                                auto elem = cast(Element)item;
                                if (elem.namespaceURI == namespaceURI && elem.localName == localName)
                                    return elem;
                            }
                                
                            auto res = findNext(cast(Node)item);
                            if (res !is null)
                                return res;
                        }
                        return null;
                    }
                    
                    // methods specific to NodeList
                    override
                    {
                        @property size_t length()
                        {
                            size_t res = 0;
                            auto node = findNext(document);
                            while (node !is null)
                            {
                                res++;
                                node = findNext(node);
                            }
                            return res;
                        }
                        Element item(size_t i)
                        {
                            auto res = findNext(document);
                            while (res && i > 0)
                            {
                                res = findNext(res);
                                i--;
                            }
                            return res;
                        }
                    }
                }
                auto res = allocator.make!ElementList;
                res.document = this;
                res.namespaceURI = namespaceURI;
                res.localName = localName;
                return res;
            }
            Element getElementById(DOMString elementId) { return null; }

            Node importNode(dom.Node!DOMString importedNode, bool deep) { return null; } 
            Node adoptNode(dom.Node!DOMString source) { return null; } 

            @property DOMString inputEncoding() { return null; }
            @property DOMString xmlEncoding() { return null; }
            
            @property bool xmlStandalone() { return _standalone; }
            @property void xmlStandalone(bool b) { _standalone = b; }

            @property DOMString xmlVersion() { return _xmlVersion; }
            @property void xmlVersion(DOMString ver)
            {
                if (ver == "1.0" || ver == "1.1")
                    _xmlVersion = ver;
                else
                    throw allocator.make!DOMException(dom.ExceptionCode.NOT_SUPPORTED);
            }

            @property bool strictErrorChecking() { return _strictErrorChecking; }
            @property void strictErrorChecking(bool b) { _strictErrorChecking = b; }
            
            @property DOMString documentURI() { return _documentURI; }
            @property void documentURI(DOMString uri) { _documentURI = uri; }
            
            @property DOMConfiguration domConfig() { return _config; }
            void normalizeDocument() { }
            Node renameNode(dom.Node!DOMString n, DOMString namespaceURI, DOMString qualifiedName) { return null; } 
        }
        private
        {
            DOMString _documentURI, _xmlVersion = "1.0";
            DocumentType _doctype;
            Element _root;
            DOMConfiguration _config;
            bool _strictErrorChecking = true, _standalone = false;
        }
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.DOCUMENT; }
            @property DOMString nodeName() { return "#document"; }
            
            DOMString lookupPrefix(DOMString namespaceURI)
            {
                return documentElement.lookupPrefix(namespaceURI);
            }
            DOMString lookupNamespaceURI(DOMString prefix)
            {
                return documentElement.lookupNamespaceURI(prefix);
            }
            bool isDefaultNamespace(DOMString namespaceURI)
            {
                return documentElement.isDefaultNamespace(namespaceURI);
            }
        }
        // inherited from NodeWithChildren
        override
        {
            Node insertBefore(dom.Node!DOMString newChild, dom.Node!DOMString refChild)
            {
                if (newChild.nodeType == dom.NodeType.ELEMENT)
                {
                    if (_root)
                        throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                        
                    auto res = super.insertBefore(newChild, refChild);
                    _root = cast(Element)newChild;
                    return res;
                }
                else if (newChild.nodeType == dom.NodeType.DOCUMENT_TYPE)
                {
                    if (_doctype)
                        throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                        
                    auto res = super.insertBefore(newChild, refChild);
                    _doctype = cast(DocumentType)newChild;
                    return res;
                }
                else if (newChild.nodeType != dom.NodeType.COMMENT && newChild.nodeType != dom.NodeType.PROCESSING_INSTRUCTION)
                    throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                else
                    return super.insertBefore(newChild, refChild);
            }
            Node replaceChild(dom.Node!DOMString newChild, dom.Node!DOMString oldChild)
            {
                if (newChild.nodeType == dom.NodeType.ELEMENT)
                {
                    if (oldChild !is _root)
                        throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                        
                    auto res = super.replaceChild(newChild, oldChild);
                    _root = cast(Element)newChild;
                    return res;
                }
                else if (newChild.nodeType == dom.NodeType.DOCUMENT_TYPE)
                {
                    if (oldChild !is _doctype)
                        throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                        
                    auto res = super.replaceChild(newChild, oldChild);
                    _doctype = cast(DocumentType)newChild;
                    return res;
                }
                else if (newChild.nodeType != dom.NodeType.COMMENT && newChild.nodeType != dom.NodeType.PROCESSING_INSTRUCTION)
                    throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                else
                    return super.replaceChild(newChild, oldChild);
            }
            Node removeChild(dom.Node!DOMString oldChild)
            {
                if (oldChild.nodeType == dom.NodeType.ELEMENT)
                {
                    auto res = super.removeChild(oldChild);
                    _root = null;
                    return res;
                }
                else if (oldChild.nodeType == dom.NodeType.DOCUMENT_TYPE)
                {
                    auto res = super.removeChild(oldChild);
                    _doctype = null;
                    return res;
                }
                else
                    return super.removeChild(oldChild);
            }
            Node appendChild(dom.Node!DOMString newChild)
            {
                if (newChild.nodeType == dom.NodeType.ELEMENT)
                {
                    if (_root)
                        throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                        
                    auto res = super.appendChild(newChild);
                    _root = cast(Element)newChild;
                    return res;
                }
                else if (newChild.nodeType == dom.NodeType.DOCUMENT_TYPE)
                {
                    if (_doctype)
                        throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                        
                    auto res = super.appendChild(newChild);
                    _doctype = cast(DocumentType)newChild;
                    return res;
                }
                else
                    return super.appendChild(newChild);
            }
        }
    }
    abstract class CharacterData: Node, dom.CharacterData!DOMString
    {
        // specific to CharacterData
        override
        {
            @property DOMString data() { return _data; }
            @property void data(DOMString newVal) { _data = newVal; }
            @property size_t length() { return _data.length; }
            
            DOMString substringData(size_t offset, size_t count)
            {
                if (offset > length)
                    throw allocator.make!DOMException(dom.ExceptionCode.INDEX_SIZE);

                import std.algorithm: min;
                return _data[offset..min(offset + count, length)];
            }
            void appendData(DOMString arg)
            {
                _data ~= arg;
            }
            void insertData(size_t offset, DOMString arg)
            {
                if (offset > length)
                    throw allocator.make!DOMException(dom.ExceptionCode.INDEX_SIZE);

                _data = _data[0..offset] ~ arg ~ _data[offset..$];
            }
            void deleteData(size_t offset, size_t count)
            {
                if (offset > length)
                    throw allocator.make!DOMException(dom.ExceptionCode.INDEX_SIZE);

                import std.algorithm: min;
                data = _data[0..offset] ~ _data[min(offset + count, length)..$];
            }
            void replaceData(size_t offset, size_t count, DOMString arg)
            {
                if (offset > length)
                    throw allocator.make!DOMException(dom.ExceptionCode.INDEX_SIZE);

                import std.algorithm: min;
                _data = _data[0..offset] ~ arg ~ _data[min(offset + count, length)..$];
            }
        }
        // inherited from Node
        override
        {
            @property DOMString nodeValue() { return data; }
            @property void nodeValue(DOMString newVal) { data = newVal; }
            @property DOMString textContent() { return data; }
            @property void textContent(DOMString newVal) { data = newVal; }
        }
        private
        {
            DOMString _data;
            
            // internal method
            private void performClone(CharacterData dest, bool deep)
            {
                super.performClone(dest, deep);
                dest._data = _data;
            }
        }
    }
    private abstract class NodeWithNamespace: NodeWithChildren
    {
        private
        {
            DOMString _name, _namespaceURI;
            size_t _colon;
            
            void setQualifiedName(DOMString name)
            {
                import std.experimental.xml.faststrings;
                
                _name = name;
                ptrdiff_t i = name.fastIndexOf(':');
                if (i > 0)
                    _colon = i;
            }
            void performClone(NodeWithNamespace dest, bool deep)
            {
                super.performClone(dest, deep);
                dest._name = _name;
                dest._namespaceURI = namespaceURI;
                dest._colon = _colon;
            }
        }
        // inherited from Node
        override
        {
            @property DOMString nodeName() { return _name; }
            
            @property DOMString localName()
            {
                if (!_colon)
                    return null;
                return _name[(_colon+1)..$];
            }
            @property DOMString prefix()
            {
                return _name[0.._colon];
            }
            @property void prefix(DOMString pre)
            {
                _name = pre ~ ':' ~ localName;
                _colon = pre.length;
            }
            @property DOMString namespaceURI() { return _namespaceURI; }
        }
    }
    class Attr: NodeWithNamespace, dom.Attr!DOMString
    {
        // specific to Attr
        override
        {
            @property DOMString name() { return _name; }
            @property bool specified() { return _specified; }
            @property DOMString value()
            {
                DOMString result = [];
                auto child = rebindable(firstChild);
                while (child)
                {
                    result ~= child.textContent;
                    child = child.nextSibling;
                }
                return result;
            }
            @property void value(DOMString newVal)
            {
                while (firstChild)
                    removeChild(firstChild);
                appendChild(ownerDocument.createTextNode(newVal));
            }

            @property Element ownerElement() { return _ownerElement; }
            @property dom.XMLTypeInfo!DOMString schemaTypeInfo() { return null; }
            @property bool isId() { return false; }
        }
        private
        {
            Element _ownerElement;
            bool _specified = true;
            @property Attr _nextAttr() { return cast(Attr)_nextSibling; }
            @property Attr _previousAttr() { return cast(Attr)_previousSibling; }
        }
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.ATTRIBUTE; }
            
            @property DOMString nodeValue() { return value; }
            @property void nodeValue(DOMString newVal) { value = newVal; }
            
            // overridden because we reuse _nextSibling and _previousSibling with another meaning
            @property Attr nextSibling() { return null; }
            @property Attr previousSibling() { return null; }
            
            Attr cloneNode(bool deep)
            {
                Attr cloned = allocator.make!Attr();
                cloned.outer = this.outer;
                cloned._ownerDocument = _ownerDocument;
                super.performClone(cloned, true);
                cloned._specified = true;
                return cloned;
            }
            
            DOMString lookupPrefix(DOMString namespaceURI)
            {
                if (ownerElement)
                    return ownerElement.lookupPrefix(namespaceURI);
                return null;
            }
            DOMString lookupNamespaceURI(DOMString prefix)
            {
                if (ownerElement)
                    return ownerElement.lookupNamespaceURI(prefix);
                return null;
            }
            bool isDefaultNamespace(DOMString namespaceURI)
            {
                if (ownerElement)
                    return ownerElement.isDefaultNamespace(namespaceURI);
                return false;
            }
        }
    }
    class Element: NodeWithNamespace, dom.Element!DOMString
    {
        // specific to Element
        override
        {
            @property DOMString tagName() { return _name; }
    
            DOMString getAttribute(DOMString name)
            {
                return _attrs.getNamedItem(name).value;
            }
            void setAttribute(DOMString name, DOMString value)
            {
                auto attr = ownerDocument.createAttribute(name);
                attr.value = value;
                attr._ownerElement = this;
                _attrs.setNamedItem(attr);
            }
            void removeAttribute(DOMString name)
            {
                _attrs.removeNamedItem(name);
            }
            
            Attr getAttributeNode(DOMString name)
            {
                return _attrs.getNamedItem(name);
            }
            Attr setAttributeNode(dom.Attr!DOMString newAttr)
            {
                return _attrs.setNamedItem(newAttr);
            }
            Attr removeAttributeNode(dom.Attr!DOMString oldAttr) { return null; }
            
            DOMString getAttributeNS(DOMString namespaceURI, DOMString localName)
            {
                return _attrs.getNamedItemNS(namespaceURI, localName).value;
            }
            void setAttributeNS(DOMString namespaceURI, DOMString qualifiedName, DOMString value)
            {
                auto attr = ownerDocument.createAttributeNS(namespaceURI, qualifiedName);
                attr.value = value;
                attr._ownerElement = this;
                _attrs.setNamedItem(attr);
            }
            void removeAttributeNS(DOMString namespaceURI, DOMString localName)
            {
                _attrs.removeNamedItemNS(namespaceURI, localName);
            }
            
            Attr getAttributeNodeNS(DOMString namespaceURI, DOMString localName)
            {
                return _attrs.getNamedItemNS(namespaceURI, localName);
            }
            Attr setAttributeNodeNS(dom.Attr!DOMString newAttr) { return null; }
            
            bool hasAttribute(DOMString name)
            {
                return _attrs.getNamedItem(name) !is null;
            }
            bool hasAttributeNS(DOMString namespaceURI, DOMString localName)
            {
                return _attrs.getNamedItemNS(namespaceURI, localName) !is null;
            }
            
            void setIdAttribute(DOMString name, bool isId) { return; }
            void setIdAttributeNS(DOMString namespaceURI, DOMString localName, bool isId) { return; }
            void setIdAttributeNode(dom.Attr!DOMString idAttr, bool isId) { return; }
            
            dom.NodeList!DOMString getElementsByTagName(DOMString name) { return null; }
            dom.NodeList!DOMString getElementsByTagNameNS(DOMString namespaceURI, DOMString localName) { return null; }
            
            @property dom.XMLTypeInfo!DOMString schemaTypeInfo() { return null; }
        }
        private
        {
            Map _attrs;
            
            // internal methods
            DOMString lookupNamespacePrefix(DOMString namespaceURI, Element originalElement)
            {
                if (this.namespaceURI && this.namespaceURI == namespaceURI
                    && this.prefix && originalElement.lookupNamespaceURI(this.prefix) == namespaceURI)
                {
                    return this.prefix;
                }
                if (hasAttributes)
                    foreach (attr; attributes)
                        if (attr.prefix == "xmlns" && attr.value == namespaceURI && originalElement.lookupNamespaceURI(attr.localName) == namespaceURI)
                            return attr.localName;
                        
                auto parentElement = parentElement();
                if (parentElement)
                    return parentElement.lookupNamespacePrefix(namespaceURI, originalElement);
                return null;
            }
        }
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.ELEMENT; }
            
            @property Map attributes() { return _attrs.length > 0 ? _attrs : null; }
            bool hasAttributes() { return _attrs.length > 0; }
            
            Element cloneNode(bool deep)
            {
                auto cloned = allocator.make!Element();
                cloned._ownerDocument = ownerDocument;
                cloned.outer = this.outer;
                super.performClone(cloned, deep);
                return cloned;
            }
            
            DOMString lookupPrefix(DOMString namespaceURI)
            {
                return lookupNamespacePrefix(namespaceURI, this);
            }
            DOMString lookupNamespaceURI(DOMString prefix)
            {
                if (namespaceURI && prefix == prefix)
                    return namespaceURI;
                
                if (hasAttributes)
                {
                    foreach (attr; attributes)
                        if (attr.prefix == "xmlns" && attr.localName == prefix)
                            return attr.value;
                        else if (attr.nodeName == "xmlns" && !prefix)
                            return attr.value;
                }
                auto parentElement = parentElement();
                if (parentElement)
                    return parentElement.lookupNamespaceURI(prefix);
                return null;
            }
            bool isDefaultNamespace(DOMString namespaceURI)
            {
                if (!prefix)
                    return this.namespaceURI == namespaceURI;
                if (hasAttributes)
                {
                    foreach (attr; attributes)
                        if (attr.nodeName == "xmlns")
                            return attr.value == namespaceURI;
                }
                auto parentElement = parentElement();
                if (parentElement)
                    return parentElement.isDefaultNamespace(namespaceURI);
                return false;
            }
        }
        
        class Map: dom.NamedNodeMap!DOMString
        {
            // specific to NamedNodeMap
            public override
            {
                ulong length()
                {
                    ulong res = 0;
                    auto attr = firstAttr;
                    while (attr)
                    {
                        res++;
                        attr = attr._nextAttr;
                    }
                    return res;
                }
                Attr item(ulong index)
                {
                    ulong count = 0;
                    auto res = firstAttr;
                    while (res && count < index)
                    {
                        count++;
                        res = res._nextAttr;
                    }
                    return res;
                }

                Attr getNamedItem(DOMString name)
                {
                    auto res = firstAttr;
                    while (res && res.nodeName != name)
                        res = res._nextAttr;
                    return res;
                }
                Attr setNamedItem(dom.Node!DOMString arg)
                {
                    if (arg.ownerDocument !is this.outer.ownerDocument)
                        throw allocator.make!DOMException(dom.ExceptionCode.WRONG_DOCUMENT);
                        
                    Attr attr = cast(Attr)arg;
                    if (!attr)
                        throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                    
                    if (attr._previousAttr)
                        attr._previousAttr._nextSibling = attr._nextAttr;
                    if (attr._nextAttr)
                        attr._nextAttr._previousSibling = attr._previousAttr;
                    
                    auto res = firstAttr;
                    while (res && res.nodeName != attr.nodeName)
                        res = res._nextAttr;
                    
                    if (res)
                    {
                        attr._previousSibling = res._previousAttr;
                        attr._nextSibling = res._nextAttr;
                    }
                    else
                    {
                        attr._nextSibling = firstAttr;
                        firstAttr = attr;
                    }
                    
                    return res;
                }
                Attr removeNamedItem(DOMString name)
                {
                    auto res = firstAttr;
                    while (res && res.nodeName != name)
                        res = res._nextAttr;
                    
                    if (res)
                    {
                        if (res._previousAttr)
                            res._previousAttr._nextSibling = res._nextAttr;
                        if (res._nextAttr)
                            res._nextAttr._previousSibling = res._previousAttr;
                        return res;
                    }
                    else
                        throw allocator.make!DOMException(dom.ExceptionCode.NOT_FOUND);
                }

                Attr getNamedItemNS(DOMString namespaceURI, DOMString localName)
                {
                    auto res = firstAttr;
                    while (res && (res.localName != localName || res.namespaceURI != namespaceURI))
                        res = res._nextAttr;
                    return res;
                }
                Attr setNamedItemNS(dom.Node!DOMString arg)
                {
                    if (arg.ownerDocument !is this.outer.ownerDocument)
                        throw allocator.make!DOMException(dom.ExceptionCode.WRONG_DOCUMENT);
                        
                    Attr attr = cast(Attr)arg;
                    if (!attr)
                        throw allocator.make!DOMException(dom.ExceptionCode.HIERARCHY_REQUEST);
                    
                    if (attr._previousAttr)
                        attr._previousAttr._nextSibling = attr._nextAttr;
                    if (attr._nextAttr)
                        attr._nextAttr._previousSibling = attr._previousAttr;
                    
                    auto res = firstAttr;
                    while (res && (res.localName != attr.localName || res.namespaceURI != attr.namespaceURI))
                        res = res._nextAttr;
                    
                    if (res)
                    {
                        attr._previousSibling = res._previousAttr;
                        attr._nextSibling = res._nextAttr;
                    }
                    else
                    {
                        attr._nextSibling = firstAttr;
                        firstAttr = attr;
                    }
                    
                    return res;
                }
                Attr removeNamedItemNS(DOMString namespaceURI, DOMString localName)
                {
                    auto res = firstAttr;
                    while (res && (res.localName != localName || res.namespaceURI != namespaceURI))
                        res = res._nextAttr;
                    
                    if (res)
                    {
                        if (res._previousAttr)
                            res._previousAttr._nextSibling = res._nextAttr;
                        if (res._nextAttr)
                            res._nextAttr._previousSibling = res._previousAttr;
                        return res;
                    }
                    else
                        throw allocator.make!DOMException(dom.ExceptionCode.NOT_FOUND);
                }
            }
            private
            {
                Attr firstAttr;
                Attr currentAttr;
            }
            auto front() { return currentAttr; }
            void popFront() { currentAttr = currentAttr._nextAttr; }
            bool empty() { return currentAttr is null; }
        }
    }
    class Text: CharacterData, dom.Text!DOMString
    {
        // specific to Text
        override
        {
            Text splitText(size_t offset)
            {
                if (offset > data.length)
                    throw allocator.make!DOMException(dom.ExceptionCode.INDEX_SIZE);
                auto second = ownerDocument.createTextNode(data[offset..$]);
                data = data[0..offset];
                if (parentNode)
                {
                    if (nextSibling)
                        parentNode.insertBefore(second, nextSibling);
                    else
                        parentNode.appendChild(second);
                }
                return second;
            }
            @property bool isElementContentWhitespace()
            {
                import std.experimental.xml.faststrings: fastIndexOfNeither;
                
                return _data.fastIndexOfNeither(" \r\n\t") == -1;
            }
            @property DOMString wholeText() { return data; } // <-- TODO
            @property Text replaceWholeText(DOMString newText) { return null; } // <-- TODO
        }
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.TEXT; }
            @property DOMString nodeName() { return "#text"; }
            
            Text cloneNode(bool deep)
            {
                auto cloned = allocator.make!Text();
                cloned.outer = this.outer;
                cloned._ownerDocument = _ownerDocument;
                super.performClone(cloned, deep);
                return cloned;
            }
        }
    }
    class Comment: CharacterData, dom.Comment!DOMString
    {
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.COMMENT; }
            @property DOMString nodeName() { return "#comment"; }
            
            Comment cloneNode(bool deep)
            {
                auto cloned = allocator.make!Comment();
                cloned.outer = this.outer;
                cloned._ownerDocument = _ownerDocument;
                super.performClone(cloned, deep);
                return cloned;
            }
        }
    }
    class DocumentType: Node, dom.DocumentType!DOMString
    {
        // specific to DocumentType
        override
        {
            @property DOMString name() { return _name; }
            @property dom.NamedNodeMap!DOMString entities() { return null; }
            @property dom.NamedNodeMap!DOMString notations() { return null; }
            @property DOMString publicId() { return _publicId; }
            @property DOMString systemId() { return _systemId; }
            @property DOMString internalSubset() { return _internalSubset; }
        }
        private DOMString _name, _publicId, _systemId, _internalSubset;
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.DOCUMENT_TYPE; }
            @property DOMString nodeName() { return _name; }
        }
    }
    class CDATASection: Text, dom.CDATASection!DOMString
    {
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.CDATA_SECTION; }
            @property DOMString nodeName() { return "#cdata-section"; }
            
            CDATASection cloneNode(bool deep)
            {
                auto cloned = allocator.make!CDATASection();
                cloned.outer = this.outer;
                cloned._ownerDocument = _ownerDocument;
                super.performClone(cloned, deep);
                return cloned;
            }
        }
    }
    class ProcessingInstruction: Node, dom.ProcessingInstruction!DOMString
    {
        // specific to ProcessingInstruction
        override
        {
            @property DOMString target() { return _target; }
            @property DOMString data() { return _data; }
            @property void data(DOMString newVal) { _data = newVal; }
        }
        private DOMString _target, _data;
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.PROCESSING_INSTRUCTION; }
            @property DOMString nodeName() { return target; }
            @property DOMString nodeValue() { return _data; }
            @property void nodeValue(DOMString newVal) { _data = newVal; }
            
            ProcessingInstruction cloneNode(bool deep)
            {
                auto cloned = allocator.make!ProcessingInstruction();
                cloned.outer = this.outer;
                cloned._ownerDocument = _ownerDocument;
                super.performClone(cloned, deep);
                cloned._target = _target;
                cloned._data = _data;
                return cloned;
            }
        }
    }
    class EntityReference: NodeWithChildren, dom.EntityReference!DOMString
    {
        // inherited from Node
        override
        {
            @property dom.NodeType nodeType() { return dom.NodeType.ENTITY_REFERENCE; }
            @property DOMString nodeName() { return _ent_name; }
        }
        private DOMString _ent_name;
    }
    class DOMConfiguration: dom.DOMConfiguration!DOMString
    {
        import std.meta;
        import std.traits;
    
        private
        {
            enum string always = "((x) => true)";
            
            static struct Config
            {
                string name;
                string type;
                string settable;
            }

            struct Params
            {
                @Config("cdata-sections", "bool", always) bool cdata_sections;
                @Config("comments", "bool", always) bool comments;
                @Config("entities", "bool", always) bool entities;
                @Config("error-handler", "ErrorHandler", always) ErrorHandler error_handler;
                @Config("namespace-declarations", "bool", always) bool namespace_declarations;
                @Config("split-cdata-sections", "bool", always) bool split_cdata_sections;
            }
            Params params;
            
            void assign(string field, string type)(dom.UserData val)
            {
                mixin("if (val.convertsTo!(" ~ type ~ ")) params." ~ field ~ " = val.get!(" ~ type ~ "); \n");
            }
            bool canSet(string type, string settable)(dom.UserData val)
            {
                mixin("if (val.convertsTo!(" ~ type ~ ")) return " ~ settable ~ "(val.get!(" ~ type ~ ")); \n");
                return false;
            }
        }
        // specific to DOMConfiguration
        override
        {
            void setParameter(string name, dom.UserData value)
            {
                switch (name)
                {
                    foreach (field; AliasSeq!(__traits(allMembers, Params)))
                    {
                        mixin("enum type = getUDAs!(Params." ~ field ~ ", Config)[0].type; \n");
                        mixin("case getUDAs!(Params." ~ field ~ ", Config)[0].name: assign!(field, type)(value); \n");
                    }
                    default:
                        throw allocator.make!DOMException(dom.ExceptionCode.NOT_FOUND);
                }
            }
            dom.UserData getParameter(string name)
            {
                switch (name)
                {
                    foreach (field; AliasSeq!(__traits(allMembers, Params)))
                    {
                        mixin("case getUDAs!(Params." ~ field ~ ", Config)[0].name: return dom.UserData(params." ~ field ~ "); \n");
                    }
                    default:
                        throw allocator.make!DOMException(dom.ExceptionCode.NOT_FOUND);
                }
            }
            bool canSetParameter(string name, dom.UserData value)
            {
                switch (name)
                {
                    foreach (field; AliasSeq!(__traits(allMembers, Params)))
                    {
                        mixin("enum type = getUDAs!(Params." ~ field ~ ", Config)[0].type; \n");
                        mixin("enum settable = getUDAs!(Params." ~ field ~ ", Config)[0].settable; \n");
                        mixin("case getUDAs!(Params." ~ field ~ ", Config)[0].name: return canSet!(type, settable)(value); \n");
                    }
                    default:
                        return false;
                }
            }
            @property dom.DOMStringList!string parameterNames()
            {
                return allocator.make!StringList();
            }
        }
        
        class StringList: dom.DOMStringList!string
        {
            private template MapToConfigName(Members...)
            {
                static if (Members.length > 0)
                    mixin("alias MapToConfigName = AliasSeq!(getUDAs!(Params." ~ Members[0] ~ ", Config)[0].name, MapToConfigName!(Members[1..$])); \n");
                else
                    alias MapToConfigName = AliasSeq!();
            }
            private static immutable string[] arr = [MapToConfigName!(__traits(allMembers, Params))];
            
            // specific to DOMStringList
            override
            {
                string item(size_t i) { return arr[i]; }
                size_t length() { return arr.length; }
                
                bool contains(string str)
                {
                    import std.algorithm: canFind;
                    return arr.canFind(str);
                }
            }
            alias arr this;
        }
    }
}

unittest
{
    import std.experimental.allocator.gc_allocator;
    auto impl = new DOMImplementation!(string, shared(GCAllocator))();
    
    auto doc = impl.createDocument("myNamespaceURI", "myPrefix:myRootElement", null);
    auto root = doc.documentElement;
    assert(root.prefix == "myPrefix");
    
    auto attr = doc.createAttributeNS("myAttrNamespace", "myAttrPrefix:myAttrName");
    root.setAttributeNode(attr);
    assert(root.attributes.length == 1);
    assert(root.getAttributeNodeNS("myAttrNamespace", "myAttrName") is attr);
    
    attr.value = "myAttrValue";
    assert(attr.childNodes.length == 1);
    assert(attr.firstChild.nodeType == dom.NodeType.TEXT);
    assert(attr.firstChild.nodeValue == attr.value);
    
    auto elem = doc.createElementNS("myOtherNamespace", "myOtherPrefix:myOtherElement");
    assert(root.ownerDocument is doc);
    assert(elem.ownerDocument is doc);
    root.appendChild(elem);
    assert(root.firstChild is elem);
    assert(root.firstChild.namespaceURI == "myOtherNamespace");
    
    auto comm = doc.createComment("myWonderfulComment");
    doc.insertBefore(comm, root);
    assert(doc.childNodes.length == 2);
    assert(doc.firstChild is comm);
    
    assert(comm.substringData(1, 4) == "yWon");
    comm.replaceData(0, 2, "your");
    comm.deleteData(4, 9);
    comm.insertData(4, "Questionable");
    assert(comm.data == "yourQuestionableComment");
    
    auto pi = doc.createProcessingInstruction("myPITarget", "myPIData");
    elem.appendChild(pi);
    assert(elem.lastChild is pi);
    auto cdata = doc.createCDATASection("myCDATAContent");
    elem.replaceChild(cdata, pi);
    assert(elem.lastChild is cdata);
    elem.removeChild(cdata);
    assert(elem.childNodes.length == 0);
    
    assert(doc.getElementsByTagNameNS("myOtherNamespace", "myOtherElement").item(0) is elem);
    
    doc.setUserData("userDataKey1", dom.UserData(3.14), null);
    doc.setUserData("userDataKey2", dom.UserData(new Object()), null);
    doc.setUserData("userDataKey3", dom.UserData(null), null);
    assert(doc.getUserData("userDataKey1") == 3.14);
    assert(doc.getUserData("userDataKey2").type == typeid(Object));
    assert(doc.getUserData("userDataKey3").peek!long is null);
    
    assert(elem.lookupNamespaceURI("myOtherPrefix") == "myOtherNamespace");
    assert(doc.lookupPrefix("myNamespaceURI") == "myPrefix");
    
    assert(elem.isEqualNode(elem.cloneNode(false)));
    assert(root.isEqualNode(root.cloneNode(true)));
    assert(comm.isEqualNode(comm.cloneNode(false)));
    assert(pi.isEqualNode(pi.cloneNode(false)));
};
