/*
  OpenMW - The completely unofficial reimplementation of Morrowind
  Copyright (C) 2009  Nicolay Korslund
  WWW: http://openmw.sourceforge.net/

  This file (archive.d) is part of the OpenMW package.

  OpenMW is distributed as free software: you can redistribute it
  and/or modify it under the terms of the GNU General Public License
  version 3, as published by the Free Software Foundation.

  This program is distributed in the hope that it will be useful, but
  WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  General Public License for more details.

  You should have received a copy of the GNU General Public License
  version 3 along with this program. If not, see
  http://www.gnu.org/licenses/ .

*/

// This should also be part of the generic cache system.
const int CACHE_MAGIC = 0x345AF815;

import std.mmfile;
import std.stream;
import std.string;

version(Windows)
  static int pageSize = 64*1024;
else
  static int pageSize = 4*1024;

// Info about the entire quad. TODO: Some of this (such as the texture
// scale and probably the width and radius) can be generated at
// loadtime and is common for all quads on the same level. We could
// just make a QuadLevelInfo struct.
struct QuadInfo
{
  // Basic info
  int cellX, cellY;
  int level;

  // Bounding box info
  float minHeight, maxHeight;
  float worldWidth;
  float boundingRadius;

  // Texture scale for this quad
  float texScale;

  // True if we should make the given child
  bool hasChild[4];

  // Number of mesh segments in this quad
  int meshNum;

  // Location of this quad in the main archive file. The size includes
  // everything related to this quad, including mesh data, alpha maps,
  // etc.
  size_t offset, size;
}


// Info about an alpha map belonging to a mesh
struct AlphaInfo
{
  size_t bufSize, bufOffset;

  // The texture name for this layer. The actual string is stored in
  // the archive's string buffer.
  int texName;
  int alphaName;

  // Fill the alpha texture buffer
  void fillAlphaBuffer(ubyte *abuf)
  {
    g_archive.copy(abuf, bufOffset, bufSize);
  }

  // Get the texture for this alpha layer
  char[] getTexName()
  {
    return g_archive.getString(texName);
  }

  // Get the material name to give the alpha texture
  char[] getAlphaName()
  {
    return g_archive.getString(alphaName);
  }
}

// Info about each submesh
struct MeshInfo
{
  // Bounding box info
  float minHeight, maxHeight;
  float worldWidth;

  // Vertex and index numbers
  int vertRows, vertCols;
  int indexCount;

  // Scene node position (relative to the parent node)
  float x, y;

  // Height offset to apply to all vertices
  float heightOffset;

  // Size and offset of the vertex buffer
  size_t vertBufSize, vertBufOffset;

  // Number and offset of AlphaInfo blocks
  int alphaNum;
  size_t alphaOffset;

  // Texture name. Index to the string table.
  int texName;

  // Fill the given vertex buffer
  void fillVertexBuffer(float *vbuf)
  {
    //g_archive.copy(vbuf, vertBufOffset, vertBufSize);

    // The height map and normals from the archive
    char *hmap = cast(char*)g_archive.getRelSlice(vertBufOffset, vertBufSize).ptr;

    int level = getLevel();

    // The generic part, containing the x,y coordinates and the uv
    // maps.
    float *gmap = g_archive.getVertexBuffer(level).ptr;

    // Calculate the factor to multiply each height value with. The
    // heights are very limited in range as they are stored in a
    // single byte. Normal MW data uses a factor of 8, but we have to
    // double this for each successive level since we're splicing
    // several vertices together and need to allow larger differences
    // for each vertex. The formula is 8*2^(level-1).
    float scale = 4.0 * (1<<level);

    // Merge the two data sets together into the output buffer.
    float offset = heightOffset;
    for(int y=0; y<vertRows; y++)
      {
        // The offset for the entire row is determined by the first
        // height value. All the values in a row gives the height
        // relative to the previous value, and the first value in each
        // row is relative to the first value in the previous row.
        offset += *hmap;

        // This is the 'sliding offset' for this row. It's adjusted
        // for each vertex that's added, but only affects this row.
        float rowofs = offset;
        for(int x=0; x<vertCols; x++)
          {
            hmap++; // Skip the byte we just read

            // X and Y from the pregenerated buffer
            *vbuf++ = *gmap++;
            *vbuf++ = *gmap++;

            // The height is calculated from the current offset
            *vbuf++ = rowofs * scale;

            // Normal vector.
            // TODO: Normalize?
            *vbuf++ = *hmap++;
            *vbuf++ = *hmap++;
            *vbuf++ = *hmap++;

            // UV
            *vbuf++ = *gmap++;
            *vbuf++ = *gmap++;

            // Adjust the offset for the next vertex. On the last
            // iteration this will read past the current row, but
            // that's OK since rowofs is discarded afterwards.
            rowofs += *hmap;
          }
      }
  }

  // Fill the index buffer
  void fillIndexBuffer(ushort *ibuf)
  {
    // The index buffer is pregenerated. It is identical for all
    // meshes on the same level, so just copy it over.
    ushort generic[] = g_archive.getIndexBuffer(getLevel());
    ibuf[0..generic.length] = generic[];
  }

  int getLevel()
  {
    assert(g_archive.curQuad);
    return g_archive.curQuad.level;
  }

  // Get an alpha map belonging to this mesh
  AlphaInfo *getAlphaInfo(int num)
  {
    assert(num < alphaNum && num >= 0);
    assert(getLevel() == 1);
    AlphaInfo *res = cast(AlphaInfo*)g_archive.getRelSlice
      (alphaOffset, alphaNum*AlphaInfo.sizeof);
    res += num;
    return res;
  }

  // Get the size of the alpha textures (in pixels).
  int getAlphaSize()
  { return g_archive.alphaSize; }

  // Get the texture and material name to use for this mesh.
  char[] getTexName()
  { return g_archive.getString(texName); }

  float getTexScale()
  { return g_archive.curQuad.texScale; }

  char[] getBackgroundTex()
  { return "_land_default.dds"; }
}

struct ArchiveHeader
{
  // "Magic" number to make sure we're actually reading an archive
  // file
  int magic;

  // Total number of quads in the archive
  int quads;

  // Level of the 'root' quad. There will only be one quad on this
  // level.
  int rootLevel;

  // Size of the alpha maps, in pixels along one side.
  int alphaSize;

  // Number of strings in the string table
  int stringNum;

  // Size of the string buffer
  size_t stringSize;
}

TerrainArchive g_archive;

// This class handles the cached terrain data.
struct TerrainArchive
{
  MeshInfo *curMesh;
  QuadInfo *curQuad;
  QuadInfo *rootQuad;

  void openFile(char[] name)
  {
    mmf = new MmFile(name,
                     MmFile.Mode.Read,
                     0, null, pageSize);

    // Read the index file first
    File ifile = new File(name ~ ".index");

    ArchiveHeader head;
    ifile.readExact(&head, head.sizeof);

    // Sanity check
    assert(head.magic == CACHE_MAGIC);
    assert(head.quads > 0 && head.quads < 8192);

    // Store header info
    alphaSize = head.alphaSize;

    // Read all the quads
    quadList = new QuadInfo[head.quads];
    ifile.readExact(quadList.ptr, head.quads*QuadInfo.sizeof);

    // Create an index of all the quads
    foreach(int index, qn; quadList)
      {
        int x = qn.cellX;
        int y = qn.cellY;
        int l = qn.level;

        assert(l >= 1);

        quadMap[l][x][y] = index;

        // Store the root quad
        if(l == head.rootLevel)
          {
            assert(rootQuad == null);
            rootQuad = &quadList[index];
          }
        else
          assert(l < head.rootLevel);
      }

    // Make sure the root was set
    assert(rootQuad !is null);

    // Next read the string table
    stringBuf = new char[head.stringSize];
    strings.length = head.stringNum;

    // First read the main string buffer
    ifile.readExact(stringBuf.ptr, head.stringSize);

    // Then read the string offsets
    int[] offsets = new int[head.stringNum];
    ifile.readExact(offsets.ptr, offsets.length*int.sizeof);

    // Set up the string table
    char *strptr = stringBuf.ptr;
    foreach(int i, ref str; strings)
      {
        // toString(char*) returns the string up to the zero
        // terminator byte
        str = toString(strptr + offsets[i]);
      }
    delete offsets;

    // Read the vertex buffer data
    int bufNum = head.rootLevel;
    assert(bufNum == 7);
    vertBufData.length = bufNum;
    indexBufData.length = bufNum;

    // Fill the buffers. Start at level 1.
    for(int i=1;i<bufNum;i++)
      {
        int size;

        // Vertex buffer
        ifile.read(size);
        vertBufData[i].length = size;
        ifile.readExact(vertBufData[i].ptr, size);

        // Index buffer
        ifile.read(size);
        indexBufData[i].length = size;
        ifile.readExact(indexBufData[i].ptr, size);
      }
  }

  // Get info about a given quad from the index.
  QuadInfo *getQuad(int X, int Y, int level)
  {
    int ind = quadMap[level][X][Y];
    QuadInfo *res = &quadList[ind];
    assert(res);
    return res;
  }

  // Maps the terrain and material info for a given quad into
  // memory. This is typically called right before the meshes are
  // created.
  void mapQuad(QuadInfo *info)
  {
    assert(info);

    // Store the quad for later
    curQuad = info;

    doMap(info.offset, info.size);
  }

  // Get the info struct for a given segment. Remembers the MeshInfo
  // for all later calls.
  MeshInfo *getMeshInfo(int segNum)
    {
      assert(curQuad);
      assert(segNum < curQuad.meshNum);

      // The mesh headers are at the beginning of the mapped segment.
      curMesh = cast(MeshInfo*) getRelSlice(0, MeshInfo.sizeof*curQuad.meshNum);
      curMesh += segNum;

      return curMesh;
    }

  float[] getVertexBuffer(int level)
  {
    assert(level>=1 && level<vertBufData.length);
    return vertBufData[level];
  }

  ushort[] getIndexBuffer(int level)
  {
    assert(level>=1 && level<indexBufData.length);
    return indexBufData[level];
  }

private:
  // All quad headers (from the index) are stored in this array
  QuadInfo quadList[];

  // A map of all quads. Contain indices to the above array. Indexed
  // by [level][X][Y].
  int[int][int][int] quadMap;

  // These contain pregenerated mesh data that is common for all
  // meshes on a given level.
  float[][] vertBufData;
  ushort[][] indexBufData;

  // Used for the mmapped file
  MmFile mmf;

  ubyte mapped[];

  // Stores the string table
  char[] stringBuf;
  char[][] strings;

  // Texture size of the alpha maps.
  int alphaSize;

  char[] getString(int index)
  {
    assert(index >= 0);
    assert(index < strings.length);

    return strings[index];
  }

  void doMap(size_t offset, size_t size)
  {
    assert(mmf !is null);
    assert(size);
    mapped = cast(ubyte[])mmf[offset..offset+size];
    assert(mapped.length == size);
  }

  // Get a slice of a given buffer within the mapped window. The
  // offset is relative to the start of the window, and the size must
  // fit inside the window.
  ubyte[] getRelSlice(size_t offset, size_t size)
  {
    assert(mapped.length);

    return mapped[offset..offset+size];
  }

  // Copy a given buffer from the file. The buffer might be a
  // compressed stream, so it's important that the buffers are written
  // the same as they are read. (Ie. you can't write a buffer as one
  // operation and read it as two, or vice versa. Also, buffers cannot
  // overlap.) The offset is relative to the current mapped file
  // window.
  void copy(void *dst, size_t offset, size_t inSize)
  {
    ubyte source[] = getRelSlice(offset, inSize);

    // Just copy it for now
    ubyte* dest = cast(ubyte*)dst;
    dest[0..source.length] = source[];
  }
}