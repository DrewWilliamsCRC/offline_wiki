package wikireader.indexer

import wikireader.core.ArticleSections
import wikireader.core.TitleIndex
import wikireader.core.ZimFile
import java.io.File
import kotlin.system.exitProcess
import kotlin.system.measureNanoTime

private const val USAGE = """usage:
  build <file.zim> [popular.zim ...]
                               write <file.zim>.idx, the title index the app searches. Articles that
                               also appear in the "popular" files (Kiwix's top-articles builds, most
                               select first) are ranked higher in search results.
  search <file.zim> <words>    search the index and print what the app would show
  cat <file.zim> <path>        print an item's content (follows redirects), e.g. cat wiki.zim Photosynthesis
  sections <file.zim> <path>   print an article's section headings as the app's menu lists them:
                               level, id and title, tab-separated
  info <file.zim>              print basic facts about the file"""

fun main(args: Array<String>) {
    if (args.size < 2) fail(USAGE)
    val zimFile = File(args[1])
    if (!zimFile.isFile) fail("no such file: $zimFile")
    ZimFile(zimFile).use { zim ->
        when (args[0]) {
            "build" -> {
                val started = System.nanoTime()
                val popular = args.drop(2).map { articlePaths(File(it)) }
                IndexBuilder(zim, popular) { println("[${(System.nanoTime() - started) / 1_000_000_000}s] $it") }
                    .build(TitleIndex.fileFor(zimFile))
            }
            "search" -> search(zim, zimFile, args.drop(2).joinToString(" "))
            "cat" -> {
                val entry = zim.find('C', args.getOrNull(2) ?: fail(USAGE)) ?: fail("not found: ${args[2]}")
                System.out.write(zim.content(zim.resolve(entry)))
                System.out.flush()
            }
            "sections" -> {
                val entry = zim.find('C', args.getOrNull(2) ?: fail(USAGE)) ?: fail("not found: ${args[2]}")
                for (s in ArticleSections.parse(zim.content(zim.resolve(entry)))) println("${s.level}\t${s.id}\t${s.title}")
            }
            "info" -> {
                println("entries: ${zim.entryCount}, clusters: ${zim.clusterCount}")
                println("content entries: ${zim.namespaceStart('D') - zim.namespaceStart('C')}")
                zim.find('W', "mainPage")?.let { println("main page: ${zim.resolve(it).path}") }
            }
            else -> fail(USAGE)
        }
    }
}

/** The paths of every article (not redirect) in a ZIM file. */
private fun articlePaths(file: File): Set<String> {
    if (!file.isFile) fail("no such file: $file")
    val paths = HashSet<String>()
    ZimFile(file).use { z -> z.scanEntries(z.namespaceStart('C'), z.namespaceStart('D')) { if (z.isHtml(it)) paths += it.path } }
    return paths
}

private fun search(zim: ZimFile, zimFile: File, query: String) {
    TitleIndex(TitleIndex.fileFor(zimFile)).use { index ->
        check(index.zimUuid.contentEquals(zim.uuid)) { "the index was built for a different file" }
        var hits: List<TitleIndex.Hit> = emptyList()
        val nanos = measureNanoTime { hits = index.search(query, 20) }
        for (h in hits) {
            val title = zim.entry(h.entryIndex).title
            println(if (h.entryIndex == h.targetIndex) title else "$title  ->  ${zim.entry(h.targetIndex).title}")
        }
        println("(${hits.size} results in ${nanos / 1000} µs; index has ${index.recordCount} titles)")
    }
}

private fun fail(message: String): Nothing {
    System.err.println(message)
    exitProcess(2)
}
